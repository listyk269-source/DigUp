import DigUpKit
import Foundation
import LlamaRuntime

/// `digup search-service`: the app's searcher as a process, for shells that can't link DigUpKit (the Windows and Linux
/// shell). It keeps the index open and the query encoder warm, so a search while typing costs what it costs
/// in the Mac app (tens of milliseconds), not a process start.
///
/// Protocol: one JSON request per line on stdin, one JSON response per line on stdout, carrying the request's `id`.
///   {"op":"search","q":…,"code":bool,"kinds":[…],"limit":n,"meaning":bool,"prefix_last":bool}
///       → {"hits":[…], "strong":n, "meaning":bool, "ms":{"embed":…,"search":…}}
///         `meaning` false: keyword-only (while typing, or while the encoder isn't ready); `strong`: the weaker-matches
///         fold (`Searcher.strongCount`); each hit has the fields of `digup search --json` plus segment_id, modified,
///         size and info.
///   {"op":"search_page", "q":…, "limit":40, …} → first page plus cursor, total, next_offset, has_more.
///   {"op":"search_page", "cursor":…, "offset":40, "limit":40} → next page of that stable ranking.
///         Complete FTS candidate retrieval; no 100-file/1000-segment cutoff. Metadata is read per page.
///         New queries/folder settings replace the cursor. Reload preserves the ranking; deleted files are skipped.
///         Optional integer from_year/through_year (1...9999) filter inclusive indexed capture/file years before
///         candidate budgets and pagination. Empty q with bounds or kinds browses dates without an encoder.
///   {"op":"search_calendar","kinds":[…]} → year_min/year_max for selected folders, without opening media.
///   {"op":"index_stats"} → selected-folder metadata counts, recent indexed files and whole-database size.
///   {"op":"face_status"} → opt-in face-job state, file/frame/face counts, device and fallback reason.
///   {"op":"face_start","download":true,"device":"auto|cpu|gpu","sample_seconds":2} → starts/resumes the
///         independent face sidecar. Only this explicit request can download the pinned YuNet/SFace weights.
///   {"op":"face_cancel"} → cancelling, then cancelled after owned decoders/inference stop. Resume retries the
///         interrupted file; unchanged completed files are kept. Neither operation resets the semantic index.
///   {"op":"face_auto","enabled":true,"device":"auto|cpu|gpu","sample_seconds":2} → persistent automatic
///         backfill after ordinary index commits; never downloads weights. face_cancel persistently pauses it.
///   {"op":"people_suggestions","minimum_cosine":0.5} → cached asynchronous counts of unreviewed person/face pairs.
///   {"op":"face_file","path":…, "offset":0,"limit":60} → version-bound faces, normalized boxes and actual frame PTS.
///   {"op":"face_search","face_id":n,"minimum_cosine":0.363,"offset":0,"limit":40} → ranked face observations;
///         pass index_revision on following pages. Publication expires an older ranking instead of duplicating hits.
///   {"op":"related_files","path":…, "segment":id?, "code":bool, "offset":0, "limit":12, "minimum_cosine":0.55}
///         → seed, hits, total, next_offset, has_more, basis, vector_source. Stored vectors only; no query encoder.
///   {"op":"embed_ahead","q":…,"code":bool}   → {"ok":true}: embeds and caches the text (the panel sends what's typed so
///                                               far on every keystroke, so the pause's vector is usually ready)
///   {"op":"text","segment":id,"code":bool}    → {"text":…}: the part of a file a hit points at, for the preview
///   {"op":"render","path":…,"kind":"pdf|video|image","loc":n,"pixels":n} → {"image":path}: a JPEG for a preview or a
///                                               thumbnail (a PDF's page `loc`, a video's frame at `loc` seconds, or a
///                                               picture a web view can't show, such as HEIC), made beside the requests
///                                               (typing never waits on one) and kept in <index>/previews until the
///                                               cache eviction (versioned local cache, approximately 512 MiB)
///   {"op":"reload"}                           → {"ok":true,"vectors":n,"code_vectors":n}: after indexing changed the index
///   {"op":"folders","roots":[…],"skipped":[…],"types":[…],"code_roots":[…],"code_skipped":[…]} → {"ok":true}
///   {"op":"prewarm"}                          → {"ok":true}: starts the encoder and loads the vectors (the panel opening)
///   {"op":"status"}                           → {"encoder":"stopped|starting|ready|unavailable","vectors":n,…}
///   {"op":"quit"}                             → {"ok":true}, then exit
/// The encoder exits after `--encoder-idle` seconds without a query and the vectors are released (as in the app);
/// keyword search keeps working and the next query brings both back.
final class SearchService: @unchecked Sendable {   // its state is guarded by `lock`
    private let directory: URL
    private var store: IndexStore
    private var searcher: Searcher
    private var codeStore: IndexStore?
    private var codeSearcher: Searcher?
    /// nil is the CLI's omitted filter; an explicitly empty selection searches none of the retained main index.
    private var roots: [String]?
    private var skipped: [String], types: Set<String>, codeRoots: [String], codeSkipped: [String]
    private let idleSeconds: Double
    private let device: LlamaDevice?
    private let log: URL
    private let faces: FaceService

    private var encoder: (any Embedder)?
    private var encoderState = "stopped"
    private var vectorCache: [String: [Float]] = [:]
    private var lastQuery = Date()
    private var warnedAboutSource = false
    private var snapshot: SearchSnapshot?
    private var snapshotToken = ""
    private var snapshotMeaning = false
    private var snapshotPeriod: MediaDates.Period?
    private var snapshotBrowsing = false
    private let lock = NSLock()
    private let output = NSLock()
    /// Renders for previews: two at a time, beside the request loop, each made once per file version.
    private let previews: URL
    private let previewCache: PreviewCache
    private let renderQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "DigUp.previews"; queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility; return queue
    }()
    private let faceQueries = DispatchQueue(label: "DigUp.face-queries", qos: .utility)
    private let peopleQueries = DispatchQueue(label: "DigUp.saved-people", qos: .userInitiated)

    init(index: URL, roots: [String]?, skipped: [String], types: Set<String>, codeRoots: [String],
         codeSkipped: [String], idleSeconds: Double, device: LlamaDevice?) throws {
        directory = index
        store = try IndexStore(directory: index, file: IndexStore.mainFile)
        searcher = try Searcher(store: store, loadVectors: false)
        self.roots = roots
        self.skipped = skipped
        self.types = types
        self.codeRoots = codeRoots
        self.codeSkipped = codeSkipped
        self.idleSeconds = idleSeconds
        self.device = device
        faces = FaceService(directory: index, roots: roots, skipped: skipped, types: types)
        log = index.appendingPathComponent("worker-query.log")
        previews = index.appendingPathComponent("preview-cache-v1")
        previewCache = try PreviewCache(directory: previews)
        try openCode()
    }

    private func openCode() throws {
        guard !codeRoots.isEmpty || FileManager.default.fileExists(atPath: directory.appendingPathComponent(IndexStore.codeFile).path)
        else { return }
        let store = try IndexStore(directory: directory, file: IndexStore.codeFile)
        codeStore = store
        codeSearcher = try Searcher(store: store, loadVectors: false)
    }

    func serve() -> Int32 {
        faces.startMonitoring()
        Thread.detachNewThread { [self] in idleWatch() }
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id: Any = request["id"] ?? NSNull()
            var reply: [String: Any]
            do {
                guard let op = request["op"] as? String else { throw CLIError("no op") }
                if op == "quit" {
                    renderQueue.cancelAllOperations()
                    write(["id": id, "ok": true])
                    faces.shutdown()
                    lock.withLock { stopEncoder() }
                    return 0
                }
                if ["face_file", "face_search", "people_list", "person_save", "person_faces", "face_label", "people_undo", "face_people", "people_suggestions"].contains(op) {
                    let request = UncheckedSendable(request)
                    // A semantic face ranking can take time. It must not hold a saved person's album hostage.
                    let ranking = op == "face_search" || op == "face_file" || (op == "person_faces" && request.value["mode"] as? String == "suggestions")
                    (ranking ? faceQueries : peopleQueries).async { [self] in
                        var reply: [String: Any]
                        do {
                            if op == "face_file" { reply = try faces.file(request.value) }
                            else if op == "face_search" { reply = try faces.search(request.value) }
                            else if op == "people_suggestions" { reply = try faces.suggestions(request.value) }
                            else { reply = try faces.people(op, request.value) }
                        }
                        catch { reply = ["ok": false, "error": String("\(error)".prefix(500))] }
                        reply["id"] = request.value["id"] ?? NSNull()
                        write(reply)
                    }
                    continue
                }
                if op == "render" || op == "media_details" {
                    let request = UncheckedSendable(request)
                    renderQueue.addOperation { [self] in
                        var reply: [String: Any]
                        do { reply = try op == "render" ? render(request.value) : mediaDetails(request.value) } catch {
                            reply = ["ok": false, "error": String("\(error)".prefix(500))]
                        }
                        reply["id"] = request.value["id"] ?? NSNull()
                        write(reply)
                    }
                    continue
                }
                reply = try lock.withLock { try handle(op, request) }
            } catch {
                reply = ["ok": false, "error": String("\(error)".prefix(500))]
            }
            reply["id"] = id
            write(reply)
        }
        faces.shutdown()
        lock.withLock { stopEncoder() }
        return 0
    }

    private func handle(_ op: String, _ request: [String: Any]) throws -> [String: Any] {
        switch op {
        case "face_status": return faces.status()
        case "face_start": return try faces.start(request)
        case "face_auto": return try faces.automatic(request)
        case "face_cancel": return faces.cancel()
        case "graph_search":
            let code = request["code"] as? Bool ?? false
            let paths = Array((request["paths"] as? [String] ?? []).prefix(120))
            let allowed = Set(paths.filter { accepts($0, code: code) }.map { Data($0.utf8) })
            let text = String((request["q"] as? String ?? "").prefix(2000))
            guard !text.isEmpty, let vector = vector(for: text, code: code) else {
                return ["ok": false, "error": "Semantic search is unavailable. Check the local model; filename filtering still works."]
            }
            guard let selected = code ? codeSearcher : searcher else { throw CLIError("This index is not available.") }
            guard encoder?.info.vectorSource == selected.vectorSource else { throw CLIError("The index model changed. Start a new graph.") }
            // A homogeneous neighborhood has no statistical outliers. Global z-gating would hide even identical
            // images here, so graph focus uses raw cosines: a 0.2 floor and 85% of the best current-canvas score.
            let page = try selected.snapshot(text, queryVector: vector, zGate: -.infinity, wordWeight: 0,
                acceptsPath: { allowed.contains(Data($0.utf8)) })
            let candidates = try page.page(offset: 0, limit: 120)
            let threshold = max(0.2, (candidates.compactMap(\.cosine).max() ?? 0) * 0.85)
            let hits = candidates.filter { ($0.cosine ?? -.infinity) >= threshold }.sorted { ($0.cosine ?? 0) > ($1.cosine ?? 0) }
            return ["ok": true, "hits": hits.map(hitFields), "meaning": true, "total": hits.count, "minimum_cosine": threshold]
        case "file_evidence":
            let code = request["code"] as? Bool ?? false
            guard let path = request["path"] as? String, accepts(path, code: code),
                  let selected = code ? codeStore : store else { throw CLIError("This file is outside the selected folders.") }
            var file: Int64?
            var info: [String: String] = [:]
            try selected.db.query("SELECT id, info FROM files WHERE path = ?", [.text(path)]) { row in
                file = row.int(0)
                info = row.text(1)?.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] } ?? [:]
            }
            guard let file else { throw CLIError("This file changed in the index. Refresh search results.") }
            var ocr: [[String: Any]] = []
            try selected.db.query("SELECT loc, excerpt FROM segments WHERE file = ? AND kind = 'ocr' LIMIT 10", [.int(file)]) { row in
                if let text = row.text(1), !text.isEmpty { ocr.append(["text": String(text.prefix(1000)), "loc": row.isNull(0) ? NSNull() : row.double(0) as Any]) }
            }
            return ["ok": true, "info": info, "ocr": ocr, "faces": NSNull(), "objects": NSNull()]
        case "related_counts":
            lastQuery = Date()
            let code = request["code"] as? Bool ?? false
            guard let nodes = request["nodes"] as? [[String: Any]], nodes.count <= 12,
                  let selected = code ? codeSearcher : searcher else { throw CLIError("Invalid neighbor count request") }
            let visible = Array((request["visible"] as? [String] ?? []).prefix(120))
            let types = (request["match_types"] as? [String]).map { Set($0.compactMap(MatchType.init(rawValue:))) }
            try selected.reload()
            var counts: [[String: Any]] = []
            for node in nodes {
                guard let path = node["path"] as? String, accepts(path, code: code) else { continue }
                let related = try selected.relatedFiles(to: path, segmentID: (node["segment"] as? NSNumber)?.int64Value,
                    limit: 0, minimumCosine: request["minimum_cosine"] as? Double ?? 0.75, matchTypes: types,
                    refresh: false, visiblePaths: visible, acceptsPath: { [self] in accepts($0, code: code) })
                counts.append(["path": path, "total": related.total, "unexpanded_count": related.unexpandedCount])
            }
            return ["ok": true, "counts": counts, "vector_source": selected.vectorSource as Any? ?? NSNull()]
        case "related_files":
            lastQuery = Date()
            let code = request["code"] as? Bool ?? false
            guard let path = request["path"] as? String, accepts(path, code: code),
                  FileManager.default.fileExists(atPath: FileAccess.path(path)) else {
                return ["ok": false, "error": "The file is missing or outside the selected folders."]
            }
            guard let selected = code ? codeSearcher : searcher else {
                return ["ok": false, "error": "This index is not available."]
            }
            let offset = max(0, request["offset"] as? Int ?? 0)
            let limit = min(max(1, request["limit"] as? Int ?? 12), 40)
            let kinds = (request["kinds"] as? [String]).map { Set($0.compactMap(FileKind.init(rawValue:))) }
            let started = Date()
            let related = try selected.relatedFiles(to: path, segmentID: (request["segment"] as? NSNumber)?.int64Value,
                offset: offset, limit: limit, minimumCosine: request["minimum_cosine"] as? Double ?? 0.55,
                kinds: kinds, matchTypes: (request["match_types"] as? [String]).map { Set($0.compactMap(MatchType.init(rawValue:))) },
                acceptsPath: { [self] in accepts($0, code: code) })
            if let issue = related.issue { return ["ok": false, "error": issue] }
            let next = min(offset, related.total) + min(limit, max(0, related.total - min(offset, related.total)))
            return ["ok": true, "seed": related.seed.map(hitFields) as Any? ?? NSNull(),
                "hits": related.hits.filter { FileManager.default.fileExists(atPath: FileAccess.path($0.path)) }.map(hitFields),
                "total": related.total, "next_offset": next, "has_more": next < related.total,
                "basis": related.basis, "vector_source": selected.vectorSource as Any? ?? NSNull(),
                "ms": Int(Date().timeIntervalSince(started) * 1000)]
        case "search_calendar":
            let kinds = (request["kinds"] as? [String]).map { Set($0.compactMap(FileKind.init(rawValue:))) }
            let years = try searcher.calendarYears(kinds: kinds, acceptsPath: { [self] in accepts($0, code: false) })
            return ["year_min": years.min as Any? ?? NSNull(), "year_max": years.max as Any? ?? NSNull()]
        case "search", "search_page":
            if op == "search_page", let cursor = request["cursor"] as? String {
                guard cursor == snapshotToken, snapshot != nil else {
                    return ["ok": false, "expired": true, "error": "Search changed. Refresh results to continue."]
                }
                if request.keys.contains("from_year") || request.keys.contains("through_year") {
                    guard try searchPeriod(request) == snapshotPeriod else {
                        return ["ok": false, "expired": true, "error": "Search changed. Refresh results to continue."]
                    }
                }
                return try readPage(request)
            }
            let text = request["q"] as? String ?? ""
            let code = request["code"] as? Bool ?? false
            let kinds = (request["kinds"] as? [String]).map { Set($0.compactMap(FileKind.init(rawValue:))) }
            let limit = request["limit"] as? Int ?? 40
            let period = try searchPeriod(request)
            let browsing = !code && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                (period.from != nil || period.through != nil || kinds != nil)
            let wantMeaning = request["meaning"] as? Bool ?? true
            let prefixLast = request["prefix_last"] as? Bool ?? false
            let started = Date()
            var vector: [Float]?
            var warning: String?
            if wantMeaning, !text.isEmpty {
                vector = self.vector(for: text, code: code)
                // Vectors from another model or runtime must never meet: keyword-only then, and say so once.
                if vector != nil, let indexed = (code ? codeSearcher : searcher)?.vectorSource,
                   let source = encoder?.info.vectorSource, indexed != source {
                    vector = nil
                    if !warnedAboutSource {
                        warning = "meaning search is off: the index was built with \(indexed), the encoder is \(source)"
                        warnedAboutSource = true
                    }
                }
            }
            let embedded = Date()
            if op == "search_page" {
                let selected = code ? codeSearcher : searcher
                snapshot = try selected?.snapshot(text, queryVector: vector, kinds: kinds, prefixLast: prefixLast, period: period, browse: browsing,
                    acceptsPath: { [self] in accepts($0, code: code) })
                snapshotToken = UUID().uuidString
                snapshotMeaning = vector != nil
                snapshotPeriod = period; snapshotBrowsing = browsing
                var reply = try readPage(request)
                reply["ms"] = ["embed": Int(embedded.timeIntervalSince(started) * 1000),
                               "search": Int(Date().timeIntervalSince(embedded) * 1000)]
                if let warning { reply["warning"] = warning }
                return reply
            }
            let hits: [SearchHit]
            if code {
                guard let codeSearcher else { return ["hits": [], "strong": 0, "meaning": false] }
                hits = try codeSearcher.search(text, queryVector: vector, limit: limit, prefixLast: prefixLast, period: period,
                    acceptsPath: { [self] in FolderSelection.isSearched($0, folders: codeRoots, skipped: codeSkipped) })
                    .filter { FileManager.default.fileExists(atPath: FileAccess.path($0.path)) }
            } else {
                hits = try searcher.search(text, queryVector: vector, kinds: kinds, limit: limit, prefixLast: prefixLast, period: period,
                    acceptsPath: { [self] path in
                        (roots.map { FolderSelection.isSearched(path, folders: $0, skipped: skipped) } ?? true)
                            && !types.contains((path as NSString).pathExtension.lowercased())
                    }).filter { FileManager.default.fileExists(atPath: FileAccess.path($0.path)) }
            }
            var reply: [String: Any] = [
                "hits": hits.map(hitFields), "strong": Searcher.strongCount(hits), "meaning": vector != nil,
                "ms": ["embed": Int(embedded.timeIntervalSince(started) * 1000),
                       "search": Int(Date().timeIntervalSince(embedded) * 1000)],
            ]
            if let warning { reply["warning"] = warning }
            return reply
        case "embed_ahead":
            _ = vector(for: request["q"] as? String ?? "", code: request["code"] as? Bool ?? false)
            return ["ok": true]
        case "text":
            guard let segment = (request["segment"] as? NSNumber)?.int64Value else { throw CLIError("which segment?") }
            let code = request["code"] as? Bool ?? false
            let path = request["path"] as? String
            if let path, !accepts(path, code: code) { return ["text": NSNull()] }
            return ["text": try (code ? codeSearcher : searcher)?.text(ofSegment: segment, atPath: path) ?? NSNull()]
        case "reload":
            let hadVectors = searcher.vectorsLoaded
            searcher.releaseVectors() // an older page snapshot must not retain a second vector matrix
            searcher = try Searcher(store: store, loadVectors: hadVectors)
            if let codeStore {
                let hadCodeVectors = codeSearcher?.vectorsLoaded ?? false
                codeSearcher?.releaseVectors()
                codeSearcher = try Searcher(store: codeStore, loadVectors: hadCodeVectors)
            } else {
                try openCode()
            }
            return ["ok": true, "vectors": searcher.vectorCount, "code_vectors": codeSearcher?.vectorCount ?? 0]
        case "folders":
            snapshot = nil // a removed folder must not remain visible through an older cursor
            snapshotToken = ""
            if let value = request["roots"] as? [String] { roots = value.map { Arguments.folderURL($0).path } }
            if let value = request["skipped"] as? [String] { skipped = value.map { Arguments.folderURL($0).path } }
            if let value = request["types"] as? [String] { types = IndexOptions.extensions(value.joined(separator: ",")) }
            faces.update(roots: roots, skipped: skipped, types: types)
            if let value = request["code_roots"] as? [String] { codeRoots = value.map { Arguments.folderURL($0).path } }
            if let value = request["code_skipped"] as? [String] { codeSkipped = value.map { Arguments.folderURL($0).path } }
            if codeSearcher == nil { try openCode() }
            return ["ok": true]
        case "prewarm":
            lastQuery = Date()
            _ = runningEncoder()
            if !searcher.vectorsLoaded { try searcher.reload() }
            return ["ok": true, "encoder": encoderState, "vectors": searcher.vectorCount]
        case "status":
            return ["encoder": encoderState, "vectors": searcher.vectorsLoaded ? searcher.vectorCount : 0,
                    "code_vectors": codeSearcher?.vectorsLoaded == true ? codeSearcher!.vectorCount : 0,
                    "index": store.file.path]
        case "index_stats":
            var indexes: [[String: Any]] = []
            for (name, selected, code) in [("files", Optional(store), false), ("code", codeStore, true)] {
                guard let selected else { continue }
                let stats = try selected.overview { [self] in accepts($0, code: code) }
                indexes.append(["name": name, "by_kind_and_state": stats.byKindAndState,
                    "segments": stats.segments, "vectors": stats.vectors, "unsupported_raw": stats.unsupportedRaw,
                    "bytes": IndexStore.size(of: selected.file), "last_indexed": stats.lastIndexed as Any? ?? NSNull(),
                    "recent": stats.recent.map { ["path": $0.path, "kind": $0.kind.rawValue, "size": $0.size,
                                                 "indexed_at": stats.indexedAt[$0.id] ?? 0] as [String: Any] }])
            }
            return ["indexes": indexes, "folders": roots?.count ?? 0, "code_folders": codeRoots.count,
                    "encoder": encoderState, "sampled_at": Date().timeIntervalSince1970]
        default:
            throw CLIError("unknown op \(op)")
        }
    }

    private func accepts(_ path: String, code: Bool) -> Bool {
        if code { return FolderSelection.isSearched(path, folders: codeRoots, skipped: codeSkipped) }
        return (roots.map { FolderSelection.isSearched(path, folders: $0, skipped: skipped) } ?? true)
            && !types.contains((path as NSString).pathExtension.lowercased())
    }

    private func searchPeriod(_ request: [String: Any]) throws -> MediaDates.Period {
        func year(_ key: String) throws -> Int? {
            guard let value = request[key], !(value is NSNull) else { return nil }
            guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
                  number.doubleValue.isFinite, number.doubleValue == Double(number.intValue),
                  (1...9999).contains(number.intValue) else { throw CLIError("Choose a valid year range: the first year must not exceed the last.") }
            return number.intValue
        }
        do { return try MediaDates.Period(from: year("from_year"), through: year("through_year")) }
        catch { throw CLIError("Choose a valid year range: the first year must not exceed the last.") }
    }

    private func readPage(_ request: [String: Any]) throws -> [String: Any] {
        lastQuery = Date()
        let total = snapshot?.total ?? 0
        let offset = min(max(0, request["offset"] as? Int ?? 0), total)
        let limit = min(max(1, request["limit"] as? Int ?? 40), 200)
        let next = offset + min(limit, total - offset)
        let hits = try (snapshot?.page(offset: offset, limit: limit) ?? [])
            .filter { FileManager.default.fileExists(atPath: FileAccess.path($0.path)) }
        return ["hits": hits.map(hitFields), "strong": hits.prefix { $0.score >= (snapshot?.strongThreshold ?? 0) }.count,
                "meaning": snapshotMeaning, "browsing": snapshotBrowsing,
                "from_year": snapshotPeriod?.from as Any? ?? NSNull(), "through_year": snapshotPeriod?.through as Any? ?? NSNull(), "total": total, "offset": offset, "next_offset": next,
                "has_more": next < total, "cursor": snapshotToken]
    }

    private func write(_ fields: [String: Any]) {
        output.withLock { emit(fields) }
    }

    // MARK: Previews

    /// Explicit, local hashing runs beside search and rendering, never on the WebView or search-state lock.
    private func mediaDetails(_ request: [String: Any]) throws -> [String: Any] {
        guard let path = request["path"] as? String else { throw CLIError("which file?") }
        let code = request["code"] as? Bool ?? false
        let real = FolderSelection.realPath(path)
        guard lock.withLock({ accepts(path, code: code) && accepts(real, code: code) }) else {
            throw CLIError("This file is outside the selected folders.")
        }
        let native = FileAccess.path(path)
        let before = try FileManager.default.attributesOfItem(atPath: native)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw CLIError("Not a regular file") }
        let hash = try ModelFiles.sha256(of: URL(fileURLWithPath: path))
        let after = try FileManager.default.attributesOfItem(atPath: native)
        guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
              (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
              lock.withLock({ accepts(path, code: code) && accepts(real, code: code) }) else {
            throw CLIError("The file changed while hashing. Retry after indexing finishes.")
        }
        return ["ok": true, "sha256": hash, "size": (after[.size] as? NSNumber)?.int64Value ?? 0,
                "modified": (after[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0]
    }

    private func render(_ request: [String: Any]) throws -> [String: Any] {
        guard let path = request["path"] as? String else { throw CLIError("which file?") }
        let kind = request["kind"] as? String ?? "image"
        let loc = (request["loc"] as? NSNumber)?.doubleValue
        let pixels = min(max(request["pixels"] as? Int ?? 1024, 32), 2048)
        guard let renderKind = PreviewImages.Kind(rawValue: kind), loc == nil || (loc!.isFinite && loc! >= 0) else { throw CLIError("Invalid preview options") }
        let real = FolderSelection.realPath(path)
        func allowed() -> Bool { lock.withLock { (accepts(path, code: false) && accepts(real, code: false)) || (accepts(path, code: true) && accepts(real, code: true)) } }
        guard allowed() else { throw CLIError("The preview is outside the selected folders.") }
        func version() throws -> FaceFileVersion {
            let attributes = try FileManager.default.attributesOfItem(atPath: FileAccess.path(path))
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let modified = attributes[.modificationDate] as? Date else { throw CLIError("Preview source unavailable") }
            return FaceFileVersion(path: path, kind: kind, size: size, modified: modified.timeIntervalSince1970)
        }
        let before = try version(), key = try PreviewCache.key(file: before, kind: kind, loc: loc, pixels: pixels)
        if let expected = request["expected_modified"] as? Double,
           abs(expected - before.modified) >= 0.001 || (request["expected_size"] as? NSNumber)?.int64Value != before.size {
            throw CLIError("The preview source changed. Retry after indexing.")
        }
        let image = try previewCache.image(key: key) { folder in
            let result = try PreviewImages.make(renderKind, of: path, at: loc, pixels: pixels, in: folder)
            guard try version() == before, allowed() else { throw CLIError("The preview source changed. Retry after indexing.") }
            return result
        }
        guard try version() == before, allowed() else { throw CLIError("The preview source changed. Retry after indexing.") }
        return ["image": image.path, "cached": image.cached]
    }

    // MARK: The query encoder

    /// The query's vector (cached), or nil when the encoder can't run: keyword results still work.
    private func vector(for text: String, code: Bool) -> [Float]? {
        lastQuery = Date()
        let key = (code ? "code\u{0}" : "") + text
        if let cached = vectorCache[key] { return cached }
        guard let encoder = runningEncoder() else { return nil }
        do {
            let values = try encoder.embedTexts([code ? Prompts.codeQuery(text) : Prompts.query(text)]).first ?? []
            if vectorCache.count > 256 { vectorCache.removeAll() }
            vectorCache[key] = values
            return values
        } catch {
            FileHandle.standardError.write(Data("encoder: \(error)\n".utf8))
            stopEncoder()   // the next query starts a new one
            return nil
        }
    }

    private func runningEncoder() -> (any Embedder)? {
        if let encoder { return encoder }
        guard encoderState != "unavailable" else { return nil }
        encoderState = "starting"
        do {
            let started = Date()
            let worker = try makeEmbedder(textOnly: true, log: log, qos: .userInitiated, device: device)
            encoder = worker
            encoderState = "ready"
            write(["event": "encoder", "state": "ready", "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100,
                  "source": worker.info.vectorSource])
            return worker
        } catch {
            encoderState = "unavailable"
            write(["event": "encoder", "state": "unavailable", "error": String("\(error)".prefix(300))])
            return nil
        }
    }

    private func stopEncoder() {
        encoder?.close()
        encoder = nil
        vectorCache.removeAll()
        if encoderState != "unavailable" { encoderState = "stopped" }
    }

    /// After `idleSeconds` without a query the model and the vectors go (their memory back to the system).
    private func idleWatch() {
        while true {
            Thread.sleep(forTimeInterval: 1)
            lock.withLock {
                guard encoder != nil || searcher.vectorsLoaded || codeSearcher?.vectorsLoaded == true,
                      Date().timeIntervalSince(lastQuery) > idleSeconds
                else { return }
                stopEncoder()
                searcher.releaseVectors()
                codeSearcher?.releaseVectors()
                write(["event": "encoder", "state": "stopped", "reason": "idle"])
            }
        }
    }
}

/// A value handed to another thread that only that thread uses from then on.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A hit as JSON: what `digup search --json` prints, plus what a shell's preview needs.
func hitFields(_ hit: SearchHit) -> [String: Any] {
    var row: [String: Any] = ["path": hit.path, "kind": hit.kind.rawValue, "segment": hit.segment.rawValue,
                              "segment_id": hit.segmentID, "score": hit.score, "modified": hit.modified,
                              "size": hit.size, "info": hit.info]
    if let date = MediaDates.date(captured: hit.info["taken"], modified: hit.modified) {
        row["media_date"] = date.day; row["media_date_source"] = date.source
    }
    if let z = hit.z { row["z"] = z }
    if let cosine = hit.cosine { row["cosine"] = cosine }
    if let rank = hit.keywordRank { row["keyword_rank"] = rank }
    if let loc = hit.loc { row["loc"] = loc }
    if let end = hit.locEnd { row["loc_end"] = end }
    if let focus = hit.focus { row["focus"] = focus }
    if let excerpt = hit.excerpt { row["excerpt"] = excerpt }
    if !hit.matchEvidence.isEmpty {
        row["match_types"] = hit.matchEvidence.map { $0.type.rawValue }
        row["match_evidence"] = hit.matchEvidence.map { evidence -> [String: Any] in
            var value: [String: Any] = ["type": evidence.type.rawValue]
            if let cosine = evidence.cosine { value["cosine"] = cosine }
            if let id = evidence.seedSegment { value["seed_segment"] = id }
            if let id = evidence.segment { value["segment"] = id }
            if let loc = evidence.seedLoc { value["seed_loc"] = loc }
            if let loc = evidence.loc { value["loc"] = loc }
            if let loc = evidence.locEnd { value["loc_end"] = loc }
            if let text = evidence.value { value["value"] = text }
            return value
        }
    }
    return row
}

func searchService(_ args: Arguments) throws -> Int32 {
    let service = try SearchService(
        index: args.indexFolder,
        roots: args.positional.isEmpty && !args.flags.contains("--restrict-roots") ? nil
            : args.positional.map { Arguments.folderURL($0).path },
        skipped: (args.lists["--exclude"] ?? []).map { Arguments.folderURL($0).path },
        types: IndexOptions.extensions((args.lists["--exclude-ext"] ?? []).joined(separator: ",")),
        codeRoots: (args.lists["--code-root"] ?? []).map { Arguments.folderURL($0).path },
        codeSkipped: (args.lists["--code-exclude"] ?? []).map { Arguments.folderURL($0).path },
        idleSeconds: args.values["--encoder-idle"].flatMap(Double.init) ?? 300, device: args.device)
    emit(["event": "ready", "index": args.indexFolder.path])
    return service.serve()
}
