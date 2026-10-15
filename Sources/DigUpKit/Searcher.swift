import Foundation

/// A stable ranking. Only the requested page reads file metadata and excerpts from SQLite.
/// A fresh query creates a fresh snapshot; indexing can continue between pages.
public final class SearchSnapshot {
    public let total: Int
    public let strongThreshold: Double
    private let read: (Range<Int>) throws -> [SearchHit]

    init(scores: [Double], read: @escaping (Range<Int>) throws -> [SearchHit]) {
        total = scores.count
        strongThreshold = (scores.first ?? 0) > 0 ? scores[0] * 0.5 : -.infinity
        self.read = read
    }

    public func page(offset: Int, limit: Int) throws -> [SearchHit] {
        let start = min(max(0, offset), total)
        let count = min(max(0, limit), total - start)
        return try read(start..<(start + count))
    }
}

public struct SearchHit: Sendable {
    public let path: String
    public let kind: FileKind
    public let score: Double          // fused rank score, for ordering only
    public let z: Double?             // how far the best segment stands out for this query (`Searcher.meaning`)
    public let cosine: Double?
    public let keywordRank: Int?      // 1-based rank among keyword matches
    public let segment: SegmentKind
    /// The segment the hit points at (its text is `Searcher.text(ofSegment:)`).
    public let segmentID: Int64
    public let loc: Double?           // PDF page, or seconds into audio/video
    public let locEnd: Double?
    public let excerpt: String?
    /// The file's modification date (seconds since 1970), and what indexing learned about it: "width", "height",
    /// "taken", "pages", "duration"… (see `Indexer`).
    public let modified: Double
    public let size: Int64
    public let info: [String: String]
    /// Code: the line to open at, in the stretch (`loc`…`locEnd`): where the name looked up is defined, or the first
    /// line with the query's words. Nil: the stretch's first line.
    public var focus: Double? = nil
    /// Present only for file-to-file comparisons. An empty list means semantic similarity without channel evidence.
    public var matchEvidence: [MatchEvidence] = []
}

/// A bounded page of file-to-file similarity, derived from stored vectors without running a model.
public struct RelatedFiles: Sendable {
    public let seed: SearchHit?
    public let hits: [SearchHit]
    public let total: Int
    public let basis: String
    public let issue: String?
    public let unexpandedCount: Int
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) count as meaning matches. That also
/// gives an honest "nothing found". Words rescue what a vector can't hold exactly: codes, IDs and names.
public final class Searcher {
    let store: IndexStore
    private var matrix: VectorStorage?   // rows × 768 float16, row-major
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    private var rowKind: [SegmentKind] = []
    /// False for the vectors the later pass adds (`Indexer.finishLongFiles`): scored, but they don't set the scale.
    private var rowSetsScale: [Bool] = []
    private var fileKind: [Int64: FileKind] = [:]
    private var filePath: [Int64: String] = [:]
    public private(set) var vectorSource: String?
    /// False after `releaseVectors()` (or `loadVectors: false`): keyword search still works, and the next search with
    /// a query vector loads them again.
    public private(set) var vectorsLoaded = false

    public var vectorCount: Int { rowFile.count }

    /// This is the code index's searcher (`IndexStore.codeFile`): names are looked up as names (`CodeLookup`).
    public var isCode: Bool { store.file.lastPathComponent == IndexStore.codeFile }

    /// With `loadVectors: false` only keyword search is ready; vectors load on the first meaning search. The app
    /// uses that to stay small while idle: 20k vectors are ~30 MB.
    public init(store: IndexStore, loadVectors: Bool = true) throws {
        self.store = store
        if loadVectors { try reload() } else { try reloadFiles() }
    }

    /// Reads the files and all vectors again (after indexing added some).
    public func reload() throws {
        releaseVectors()
        try reloadFiles()
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { rows = Int($0.int(0)) }
        guard let matrix = VectorStorage(rows: rows) else {
            vectorsLoaded = true   // nothing to load
            return
        }
        let rowBytes = Vectors.dimension * MemoryLayout<Float16>.stride
        let steps = IndexOptions()
        try store.db.query("""
            SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, CAST(json_extract(f.info, '$.pages') AS INTEGER)
            FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.id
            """) { row in
            guard let blob = row.blob(3), blob.count == rowBytes, rowFile.count < rows else { return }
            blob.copyBytes(to: UnsafeMutableRawBufferPointer(start: matrix.halves + rowFile.count * Vectors.dimension,
                                                             count: rowBytes))
            rowSegment.append(row.int(0))
            rowFile.append(row.int(1))
            rowModality.append(Modality(rawValue: row.text(2) ?? "") ?? .none)
            rowKind.append(SegmentKind(rawValue: row.text(4) ?? "") ?? .name)
            // Past the first step of a long PDF (its pages) or document (its chunks).
            let (kind, place) = (row.text(4), row.isNull(5) ? 0 : Int(row.double(5)))
            let later = row.text(6) == "pdf"
                ? kind != SegmentKind.chunk.rawValue && Int(row.int(7)) > steps.bigPDFPages && place > steps.pdfStep
                : kind == SegmentKind.chunk.rawValue && place > steps.docStep
            rowSetsScale.append(!later)
        }
        self.matrix = matrix
        vectorsLoaded = true
    }

    /// Frees the vectors' memory; keyword search keeps working.
    public func releaseVectors() {
        matrix = nil
        rowFile = []
        rowSegment = []
        rowModality = []
        rowKind = []
        rowSetsScale = []
        vectorsLoaded = false
    }

    private func reloadFiles() throws {
        fileKind.removeAll(keepingCapacity: true)
        filePath.removeAll(keepingCapacity: true)
        try store.db.query("SELECT id, kind, path FROM files") { row in
            fileKind[row.int(0)] = FileKind(rawValue: row.text(1) ?? "")
            filePath[row.int(0)] = row.text(2) ?? ""
        }
        vectorSource = try store.meta("vector_source")
    }

    /// How much finding the query's words counts against meaning (`search`). Code's words count for less: they're
    /// everywhere in code ("app", "running", "location"), and a stretch that shares a few of them beat the one that
    /// does what the query says (2026-10-09, the real-code eval of 27 queries over DigUp, Sparkle and llama.cpp: 18 → 20
    /// found first, the top 5 unchanged; the synthetic code eval 40 → 41 of 41; 1.5 changed nothing, 0.5 lost the top 5).
    public static let wordWeight = 2.0
    public static let codeWordWeight = 1.0

    /// A matched fragment anchors the neighborhood when supplied; otherwise use the normalized mean of the file's
    /// valid vectors. Every other file contributes its closest fragment once. Cosine is similarity, not probability.
    /// Filters run before ranking/paging; live SQLite path/segment ownership is checked again when reading a node.
    public func relatedFiles(to path: String, segmentID: Int64? = nil, offset: Int = 0, limit: Int = 12,
                             minimumCosine: Double = 0.55, kinds: Set<FileKind>? = nil,
                             matchTypes: Set<MatchType>? = nil, refresh: Bool = true,
                             visiblePaths: [String] = [],
                             acceptsPath: ((String) -> Bool)? = nil) throws -> RelatedFiles {
        func unavailable(_ issue: String) -> RelatedFiles {
            RelatedFiles(seed: nil, hits: [], total: 0, basis: "", issue: issue, unexpandedCount: 0)
        }
        guard acceptsPath?(path) ?? true else { return unavailable("This file is outside the selected folders.") }
        // Start a fresh vector view: indexing can replace row IDs or the model between graph expansions.
        if refresh || !vectorsLoaded { try reload() }
        guard let file = filePath.first(where: { $0.value.utf8.elementsEqual(path.utf8) })?.key,
              let matrix else { return unavailable("This file has no indexed vectors yet.") }
        let rows = rowFile.indices.filter { rowFile[$0] == file }
        guard !rows.isEmpty else { return unavailable("This file has no indexed vectors yet.") }
        var matched: Int?
        if let segmentID {
            var owned = false
            try store.db.query("SELECT 1 FROM segments WHERE id = ? AND file = ?", [.int(segmentID), .int(file)]) { _ in owned = true }
            guard owned else { return unavailable("The indexed fragment changed. Refresh search results.") }
            matched = rows.first { rowSegment[$0] == segmentID }
        }
        var vector = [Float](repeating: 0, count: Vectors.dimension)
        var validRows: [Int] = []
        for row in matched.map({ [$0] }) ?? rows {
            let halves = matrix.halves + row * Vectors.dimension
            guard (0..<Vectors.dimension).allSatisfy({ halves[$0].isFinite }) else { continue }
            let squared = (0..<Vectors.dimension).reduce(0.0) { $0 + pow(Double(halves[$1]), 2) }
            guard squared > 0 else { continue }
            validRows.append(row)
            for column in vector.indices { vector[column] += Float(halves[column]) }
        }
        let squared = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squared.isFinite, squared > 0, let first = validRows.first else {
            return unavailable("This file has no usable indexed vectors yet.")
        }
        let norm = Float(sqrt(squared))
        vector = vector.map { $0 / norm }
        guard let seed = try relatedHit(file: file, row: first, cosine: nil) else {
            return unavailable("This file changed in the index. Refresh search results.")
        }
        let accepted = Set(filePath.compactMap { id, value in
            id != file && (acceptsPath?(value) ?? true) && (kinds == nil || fileKind[id].map { kinds!.contains($0) } ?? false)
                ? id : nil
        })
        let threshold = minimumCosine.isFinite ? min(1, max(-1, minimumCosine)) : 0.55
        let scores = score(vector)
        // Score each supported channel against its own seed mean. Never relabel a general/cross-modal score as a face/OCR match.
        let channelRows: [(MatchType, [Int])] = [(.visual, rows.filter { rowModality[$0] == .image }),
            (.audio, rows.filter { rowModality[$0] == .audio }), (.ocr, rows.filter { rowKind[$0] == .ocr })]
        var channelBest: [MatchType: [Int64: (cosine: Double, row: Int, anchor: Int?)]] = [:]
        for (type, candidates) in channelRows {
            let anchors = matched.flatMap { candidates.contains($0) ? [$0] : nil } ?? candidates
            var mean = [Float](repeating: 0, count: Vectors.dimension), valid: [Int] = []
            for row in anchors {
                let halves = matrix.halves + row * Vectors.dimension
                guard (0..<Vectors.dimension).allSatisfy({ halves[$0].isFinite }) else { continue }
                valid.append(row)
                for column in mean.indices { mean[column] += Float(halves[column]) }
            }
            let length = sqrt(mean.reduce(0.0) { $0 + Double($1) * Double($1) })
            guard length.isFinite, length > 0 else { continue }
            let channelScores = score(mean.map { $0 / Float(length) })
            for row in channelScores.indices where accepted.contains(rowFile[row]) && channelScores[row].isFinite {
                let same = type == .visual ? rowModality[row] == .image : type == .audio ? rowModality[row] == .audio : rowKind[row] == .ocr
                let cosine = min(1, max(-1, Double(channelScores[row])))
                if same && cosine >= threshold && cosine > (channelBest[type]?[rowFile[row]]?.cosine ?? -.infinity) {
                    channelBest[type, default: [:]][rowFile[row]] = (cosine, row, valid.count == 1 ? valid.first : nil)
                }
            }
        }
        var metadataFiles = Set<Int64>()
        if let taken = seed.info["taken"], !taken.isEmpty {
            try store.db.query("SELECT id FROM files WHERE json_extract(info, '$.taken') = ?", [.text(taken)]) {
                if accepted.contains($0.int(0)) { metadataFiles.insert($0.int(0)) }
            }
        }
        var best: [Int64: (cosine: Double, row: Int)] = [:]
        for row in scores.indices where accepted.contains(rowFile[row]) && scores[row].isFinite {
            let cosine = min(1, max(-1, Double(scores[row])))
            if cosine >= threshold && cosine > (best[rowFile[row]]?.cosine ?? -.infinity) {
                best[rowFile[row]] = (cosine, row)
            }
        }
        if let matchTypes {
            best = best.filter { metadataFiles.contains($0.key) && matchTypes.contains(.metadata) }
        }
        for (type, files) in channelBest where matchTypes == nil || matchTypes!.contains(type) {
            for (file, value) in files where value.cosine > (best[file]?.cosine ?? -.infinity) {
                best[file] = (value.cosine, value.row)
            }
        }
        let ranking = best.sorted { $0.value.cosine > $1.value.cosine || ($0.value.cosine == $1.value.cosine && $0.key < $1.key) }
        let start = min(max(0, offset), ranking.count)
        let end = start + min(max(0, min(limit, 40)), ranking.count - start)
        var hits: [SearchHit] = []
        for item in ranking[start..<end] {
            guard var hit = try relatedHit(file: item.key, row: item.value.row, cosine: item.value.cosine) else { continue }
            for type in [MatchType.visual, .audio, .ocr] {
                guard let evidence = channelBest[type]?[item.key],
                      let target = try relatedHit(file: item.key, row: evidence.row, cosine: evidence.cosine) else { continue }
                let anchor = try evidence.anchor.flatMap { try relatedHit(file: file, row: $0, cosine: nil) }
                hit.matchEvidence.append(MatchEvidence(type: type, cosine: evidence.cosine, seedSegment: anchor?.segmentID,
                    segment: target.segmentID, seedLoc: anchor?.loc, loc: target.loc, locEnd: target.locEnd, value: nil))
            }
            if metadataFiles.contains(item.key) {
                hit.matchEvidence.append(MatchEvidence(type: .metadata, cosine: nil, seedSegment: nil,
                    segment: nil, seedLoc: nil, loc: nil, locEnd: nil, value: seed.info["taken"]))
            }
            hits.append(hit)
        }
        let visible = Set(visiblePaths.map { Data($0.utf8) })
        let unexpanded = ranking.filter { item in filePath[item.key].map { !visible.contains(Data($0.utf8)) } ?? false }.count
        return RelatedFiles(seed: seed, hits: hits, total: ranking.count,
                            basis: matched == nil ? "file_mean" : "matched_fragment", issue: nil, unexpandedCount: unexpanded)
    }

    private func relatedHit(file: Int64, row: Int, cosine: Double?) throws -> SearchHit? {
        var hit: SearchHit?
        try store.db.query("""
            SELECT f.path, f.kind, f.mtime, f.size, f.info, s.kind, s.loc, s.loc_end, s.excerpt
            FROM files f JOIN segments s ON s.file = f.id WHERE f.id = ? AND s.id = ?
            """, [.int(file), .int(rowSegment[row])]) { record in
            let path = record.text(0) ?? ""
            guard !path.isEmpty, filePath[file]?.utf8.elementsEqual(path.utf8) == true else { return }
            let info = record.text(4)?.data(using: .utf8).flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: String]
            } ?? [:]
            hit = SearchHit(path: path, kind: FileKind(rawValue: record.text(1) ?? "") ?? .doc,
                score: cosine ?? 1, z: nil, cosine: cosine, keywordRank: nil,
                segment: SegmentKind(rawValue: record.text(5) ?? "") ?? .name, segmentID: rowSegment[row],
                loc: record.isNull(6) ? nil : record.double(6), locEnd: record.isNull(7) ? nil : record.double(7),
                excerpt: record.text(8), modified: record.double(2), size: record.int(3), info: info)
        }
        return hit
    }

    public func search(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil, limit: Int = 20,
                       zGate: Double = 2.0, wordWeight: Double? = nil, prefixLast: Bool = false,
                       acceptsPath: ((String) -> Bool)? = nil) throws -> [SearchHit] {
        try snapshot(text, queryVector: queryVector, kinds: kinds, zGate: zGate, wordWeight: wordWeight,
                     prefixLast: prefixLast, acceptsPath: acceptsPath, complete: false).page(offset: 0, limit: limit)
    }

    /// Complete candidate retrieval for paged search. The existing CLI/Mac top-k API retains its candidate budget.
    public func snapshot(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil,
                         zGate: Double = 2.0, wordWeight: Double? = nil, prefixLast: Bool = false,
                         acceptsPath: ((String) -> Bool)? = nil, complete: Bool = true) throws -> SearchSnapshot {
        let wordWeight = wordWeight ?? (isCode ? Self.codeWordWeight : Self.wordWeight)
        if queryVector != nil, !vectorsLoaded { try reload() }
        let fileKind = self.fileKind
        let accepted = acceptsPath.map { predicate in Set(filePath.compactMap { predicate($0.value) ? $0.key : nil }) }
        let allowed = { (file: Int64) -> Bool in
            (accepted?.contains(file) ?? true) && (kinds == nil || fileKind[file].map { kinds!.contains($0) } ?? false)
        }
        // Filter before both candidate limits: retained rows outside the current selection must not crowd out its
        // matches. Only database-generated integer IDs enter SQL; folder names and document contents never do.
        var fileConstraint = ""
        if accepted != nil || kinds != nil {
            let files = fileKind.keys.filter(allowed).sorted()
            guard !files.isEmpty else { return SearchSnapshot(scores: [], read: { _ in [] }) }
            fileConstraint = " AND s.file IN (" + files.map(String.init).joined(separator: ",") + ")"
        }

        // Meaning: score every vector on this query's scale (`meaning`), keep each file's best segment.
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        if let query = queryVector, query.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(query)
            // A removed folder also stops setting the semantic baseline. Kind-only filters retain their previous
            // whole-index scale; an explicit path selection uses only its eligible first-pass vectors.
            let scale = accepted.map { files in rowFile.indices.map { rowSetsScale[$0] && files.contains(rowFile[$0]) } }
                ?? rowSetsScale
            let meaning = Self.meaning(scores, rowModality, setsScale: scale)
            for row in 0..<scores.count where allowed(rowFile[row]) {
                let z = meaning[row]
                if z > (best[rowFile[row]]?.z ?? -.infinity) { best[rowFile[row]] = (z, Double(scores[row]), row) }
            }
        }

        // Words: FTS5 with Porter stemming over file names, folder names, OCR, page and document text. A name from code
        // ("quantize_row_q8_0_ref") is matched as one phrase, as it's written.
        let terms = Self.terms(text)
        let identifier = isCode ? CodeLookup.identifier(text) : nil
        var words: [(file: Int64, segment: Int64, snippet: String?)] = []
        var coverage: [Int64: Double] = [:]   // share of the query's words found anywhere in the file
        var patterns = identifier.map { [CodeLookup.phrase($0)] } ?? Self.patterns(terms, prefixLast: prefixLast)
        // A word that's in no file as typed matches as the start of longer words, as the last word does while it's
        // being typed: "grok" finds "Grok4" and "Grokipedia" (stemming only covers endings, as in "grokking").
        // Otherwise a file the panel showed while you typed dropped out once you stopped. A word that is in the index
        // as typed stays whole, so "cat" doesn't bring in "category"; so does a word of two letters, the start of too
        // many words to stand for one.
        if identifier == nil {
            for index in terms.indices where terms[index].count >= 3 && !patterns[index].hasSuffix("*") {
                if try !isIndexed(patterns[index], fileConstraint: fileConstraint) { patterns[index] += "*" }
            }
        }
        if !patterns.isEmpty {
            var seen = Set<Int64>()
            let budget = complete ? "" : " LIMIT 1000"
            try store.db.query("""
                SELECT s.file, s.id, snippet(fts, 1, '«', '»', '…', 12), fts.original FROM fts
                JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? \(fileConstraint) ORDER BY bm25(fts, 3.0, 1.0), s.id\(budget)
                """, [.text(patterns.joined(separator: " OR "))]) { row in
                let file = row.int(0)
                guard (complete || words.count < 100), allowed(file), seen.insert(file).inserted else { return }
                // Text that normalizing changed is quoted as it's written (with its hamza, harakat, joiners).
                let snippet = row.text(3).flatMap { SearchText.snippet($0, terms: terms) } ?? row.text(2)
                words.append((file, row.int(1), snippet))
            }
            if !words.isEmpty {
                let files = words.map { String($0.file) }.joined(separator: ",")
                for pattern in patterns {
                    try store.db.query("""
                        SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid
                        WHERE fts MATCH ? AND s.file IN (\(files))
                        """, [.text(pattern)]) { coverage[$0.int(0), default: 0] += 1 / Double(patterns.count) }
                }
            }
        }

        // A file qualifies by standing out in meaning, or by containing at least half of the query's words.
        // Score: meaning z + a bonus that grows with word coverage, + 1 for the kind the query asks for.
        // One common word can't beat a strong meaning match; all the words of an exact lookup usually do.
        // (This beat reciprocal-rank fusion on both evals, 2026-10-07: R@1 0.88 vs 0.73 synthetic, 0.86 vs 0.82 real.)
        let lookup = Self.isLookup(terms) || identifier != nil
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
        let hinted = Self.kindHints(text)
        var candidates = Set(best.filter { $0.value.z >= zGate }.keys)
        for (file, share) in coverage where share >= 0.5 { candidates.insert(file) }
        var scored: [Int64: Double] = [:]
        for file in candidates {
            var score = meaningWeight * max(best[file]?.z ?? 0, 0) + wordsWeight * pow(coverage[file] ?? 0, 1.5)
            if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
            scored[file] = score
        }

        let wordRank = Dictionary(words.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) },
                                  uniquingKeysWith: { first, _ in first })
        let ranking = scored.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) })
        return SearchSnapshot(scores: ranking.map(\.value)) { [self, rowSegment, filePath] range in
            var hits: [SearchHit] = []
            for rank in range {
                let (file, score) = ranking[rank]
                let semantic = best[file]
                let keyword = wordRank[file]
                // Point at the best meaning segment if it stands out; else at the segment the words matched.
                let useMeaning = semantic.map { $0.z >= zGate || keyword == nil } ?? false
                guard var segmentID = useMeaning ? semantic.map({ rowSegment[$0.row] }) : keyword?.1.segment else { continue }
                var focus: Double?
                if isCode {
                    // Where a name is defined is looked for in the first 10 results only: a name used all over a big repo
                    // (ggml_tensor) is in hundreds of stretches of every file that has it (2026-10-09, llama.cpp and two
                    // more repos: 560 → 100 ms a search; the others take 10–50 ms).
                    (segmentID, focus) = try codePlace(file: file, segment: segmentID,
                                                       identifier: rank < 10 ? identifier : nil, query: text, terms: terms,
                                                       wordsHere: keyword?.1.segment == segmentID || identifier != nil)
                }
                var path = "", kind = FileKind.doc, modified = 0.0, size: Int64 = 0, info: [String: String] = [:]
                try store.db.query("SELECT path, kind, mtime, size, info FROM files WHERE id = ?", [.int(file)]) {
                    path = $0.text(0) ?? ""
                    kind = FileKind(rawValue: $0.text(1) ?? "") ?? .doc
                    modified = $0.double(2)
                    size = $0.int(3)
                    if let json = $0.text(4)?.data(using: .utf8) {
                        info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
                    }
                }
                // SQLite path identity is byte-based; Swift String equality also equates distinct Unicode spellings.
                guard !path.isEmpty, filePath[file]?.utf8.elementsEqual(path.utf8) == true else { continue }
                var segment = SegmentKind.name, loc: Double?, locEnd: Double?, storedExcerpt: String?
                var foundSegment = false
                try store.db.query("SELECT kind, loc, loc_end, excerpt FROM segments WHERE id = ? AND file = ?", [.int(segmentID), .int(file)]) {
                    foundSegment = true
                    segment = SegmentKind(rawValue: $0.text(0) ?? "") ?? .name
                    loc = $0.isNull(1) ? nil : $0.double(1)
                    locEnd = $0.isNull(2) ? nil : $0.double(2)
                    storedExcerpt = $0.text(3)
                }
                guard foundSegment else { continue } // deleted/reindexed IDs can be reused by another file
                // Quote the matched words only when they come from the segment we point at, so a PDF hit on page 5
                // never shows page 2's words. A segment with no place and no text of its own (a screenshot's image
                // vector) can borrow them from its file's OCR text, which describes the same picture.
                var snippet = keyword.flatMap { $0.1.segment == segmentID ? $0.1.snippet : nil }
                    .flatMap { $0.contains("«") ? excerpt($0, limit: 400) : nil }
                if snippet == nil, storedExcerpt == nil, loc == nil, let match = keyword?.1,
                   let text = match.snippet, text.contains("«") {
                    var matchedKind: String?
                    try store.db.query("SELECT kind FROM segments WHERE id = ?", [.int(match.segment)]) {
                        matchedKind = $0.text(0)
                    }
                    if matchedKind != SegmentKind.name.rawValue { snippet = excerpt(text, limit: 400) }
                }
                hits.append(SearchHit(path: path, kind: kind, score: score, z: semantic?.z, cosine: semantic?.cosine,
                                      keywordRank: keyword?.0, segment: segment, segmentID: segmentID, loc: loc,
                                      locEnd: locEnd,
                                      excerpt: snippet ?? storedExcerpt, modified: modified, size: size, info: info,
                                      focus: focus))
            }
            return hits
        }
    }

    /// Code: the stretch to point at, and the line in it to open at. A name looked up points at the stretch that
    /// defines it, when one does (not the ones that call it). Otherwise the line is the first with the query's words,
    /// when they matched in this stretch; a match by meaning alone opens at the stretch's first line.
    private func codePlace(file: Int64, segment: Int64, identifier: [String]?, query: String, terms: [String],
                           wordsHere: Bool) throws -> (Int64, Double?) {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "()", with: "")
        if let identifier {
            var best: (segment: Int64, line: Int, strength: Int)?
            try store.db.query("""
                SELECT s.id, s.loc, coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? AND s.file = ? ORDER BY s.loc LIMIT 300
                """, [.text(CodeLookup.phrase(identifier)), .int(file)]) { row in
                guard best?.strength ?? 0 < 2, let text = row.text(2),
                      let found = CodeLookup.definition(of: name, in: text, first: Int(row.double(1))) else { return }
                if found.strength > (best?.strength ?? 0) { best = (row.int(0), found.line, found.strength) }
            }
            if let best { return (best.segment, Double(best.line)) }
        }
        guard wordsHere || identifier != nil, let text = try text(ofSegment: segment) else { return (segment, nil) }
        var first = 1
        try store.db.query("SELECT loc FROM segments WHERE id = ?", [.int(segment)]) { first = Int($0.double(0)) }
        let words = identifier == nil ? terms : [name.lowercased()]
        return (segment, CodeLookup.firstLine(with: words, in: text, first: first).map(Double.init))
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342": an order, a phone number) mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words double and meaning half. Numbers
    /// count since 2026-10-09, when text of digits lost its vectors (`SearchText.hasWords`): a number in a data dump fell
    /// below unrelated meaning matches.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// How many of `hits` (best first) are strong: scoring at least `ratio` × the top hit. The rest pass the gates but
    /// trail far behind, and the app folds them under "weaker matches". On both evals (2026-10-07), 0.5 cut the list
    /// from 26.2 to 5.7 results per query and never folded an expected answer.
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        return hits.prefix { $0.score >= top * ratio }.count
    }

    /// Cosine similarity of `query` with every stored vector (all are L2-normalized): a matrix-vector product, done a
    /// block of rows at a time, each block turned into float32 first.
    private func score(_ query: [Float]) -> [Float] {
        let rows = rowFile.count
        var scores = [Float](repeating: 0, count: rows)
        guard let matrix, rows > 0 else { return scores }
        query.withUnsafeBufferPointer { query in
            scores.withUnsafeMutableBufferPointer { scores in
                var row = 0
                while row < rows {
                    let count = min(VectorStorage.blockRows, rows - row)
                    Vectors.floats(fromHalf: matrix.halves + row * Vectors.dimension, count: count * Vectors.dimension,
                                   to: matrix.block)
                    // (count × 768) · (768 × 1)
                    Vectors.scores(of: matrix.block, count: count, query: query.baseAddress!,
                                   into: scores.baseAddress! + row)
                    row += count
                }
            }
        }
        return scores
    }

    /// This query's meaning scores: each vector's cosine similarity minus the average of its modality (text, image and
    /// audio vectors can sit at slightly different levels for the same query), in standard deviations of all of them
    /// together. Within a modality that's the model's own order. Scaling each modality by its own deviation instead
    /// inflated the narrow ones and buried PDF pages under pictures (2026-10-08, on the three evals: 91 → 94 of 105
    /// queries with the right answer first).
    ///
    /// The scale (the averages and the deviation) comes from the vectors in `setsScale` (all by default): `search` leaves
    /// out the later pages of long files, which are scored on it but don't move it. A book's hundreds of pages pulled the
    /// text average down for every query, and documents rose over screenshots everywhere (2026-10-09, the testbed's long
    /// files finished: real eval 24 → 22 of 26 first; 24 with the scale kept).
    static func meaning(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Double] {
        let means = modalityMeans(scores, modality, setsScale: setsScale)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        var count = 0.0, sum = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            count += 1
            sum += centered[row]
        }
        let mean = sum / max(count, 1)
        var squares = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            squares += (centered[row] - mean) * (centered[row] - mean)
        }
        let deviation = max((squares / max(count, 1)).squareRoot(), 0.02)
        return centered.map { ($0 - mean) / deviation }
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    static func modalityMeans(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices where setsScale?[row] ?? true {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= 20 {
                out[modality] = sum[modality]! / Double(n)
            } else {
                out[modality] = all
            }
        }
        return out
    }

    /// The text of a page, a document's passage or a screenshot's OCR, as it's written: the preview shows the part of a
    /// document that matched.
    public func text(ofSegment id: Int64, atPath path: String? = nil) throws -> String? {
        var text: String?
        if let path {
            try store.db.query("""
                SELECT coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
                JOIN files f ON f.id = s.file WHERE s.id = ? AND f.path = ?
                """, [.int(id), .text(path)]) { text = $0.text(0) }
        } else {
            try store.db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        }
        return text
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Bengali and Arabic (normalized, as `terms` sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে", "কোথায়", "কোন", "কী", "কি", "যে",
        "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    ]

    /// The content words of a query, normalized as keyword search keeps its text (`SearchText`). Kind words
    /// ("screenshot", "video") and stopwords are dropped: they describe what to look for, not what's in it. Words of
    /// two letters or more count; a Bengali letter with its vowel sign ("মা") is two.
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return SearchText.normalized(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// FTS5 patterns for the query's words: quoted, and as prefixes for the last word while it's being typed and for
    /// words of languages that attach endings (`SearchText.inflects`). `search` makes a word that's in no file a
    /// prefix too.
    static func patterns(_ terms: [String], prefixLast: Bool) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || SearchText.inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// Whether keyword search finds `pattern` in any file.
    private func isIndexed(_ pattern: String, fileConstraint: String) throws -> Bool {
        var found = false
        try store.db.query("""
            SELECT 1 FROM fts JOIN segments s ON s.id = fts.rowid WHERE fts MATCH ? \(fileConstraint) LIMIT 1
            """, [.text(pattern)]) { _ in found = true }
        return found
    }

    /// The query's words as an FTS5 OR-query.
    public static func ftsQuery(_ text: String, prefixLast: Bool = false) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return patterns(words, prefixLast: prefixLast).joined(separator: " OR ")
    }

    static let kindWords: [String: FileKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "photo": .image, "photos": .image, "picture": .image,
        "pictures": .image, "image": .image, "images": .image, "pdf": .pdf, "pdfs": .pdf, "paper": .pdf,
        "papers": .pdf, "document": .doc, "documents": .doc, "note": .doc, "notes": .doc, "video": .video,
        "videos": .video, "clip": .video, "movie": .video, "audio": .audio, "song": .audio, "podcast": .audio,
        "voice": .audio, "sound": .audio,
        "স্ক্রিনশট": .screenshot, "ছবি": .image, "পিডিএফ": .pdf, "নোট": .doc, "ভিডিও": .video, "অডিও": .audio,
        "গান": .audio, "রেকর্ডিং": .audio,
        "لقطة": .screenshot, "صورة": .image, "صور": .image, "مستند": .doc, "ملاحظات": .doc, "فيديو": .video,
        "مقطع": .video, "صوت": .audio, "تسجيل": .audio, "اغنية": .audio,
    ]

    /// Kinds the query asks for ("…in a video", "screenshot of…", "ভিডিওতে"): a soft boost, not a filter. Bengali
    /// attaches case endings, so a Bengali kind word also counts at the start of a longer word.
    static func kindHints(_ text: String) -> Set<FileKind> {
        Set(SearchText.normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { word in
                kindWords[word] ?? kindWords.first { key, _ in
                    SearchText.inflects(key) && key.unicodeScalars.count >= 3 && word.hasPrefix(key)
                }?.value
            })
    }
}
