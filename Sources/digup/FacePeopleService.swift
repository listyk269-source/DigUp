import DigUpKit
import Foundation

/// Constructed on the face-query queue. Names are global to this local index; observations, proposals and retained
/// snapshots are always filtered by the current folder selection. Only the selected person's proposals are ranked.
final class FacePeopleService {
    private let index: FaceIndexStore
    private let store: FacePeopleStore
    private let acceptsCurrent: (FaceFileVersion) -> Bool
    private let acceptsScope: (FaceFileVersion) -> Bool
    private let checkScope: () throws -> Void
    private let mediaDate: (FaceFileVersion) -> FacePeopleAlbum.MediaDate?
    private let indexRevision: Int64
    private let peopleRevision: Int64
    private var currentAnchors: [String: Int64]?
    private var currentFiles: [Data: Bool] = [:]
    private var savedIDs: [String: Int64] = [:]
    init(directory: URL, acceptsCurrent: @escaping (FaceFileVersion) -> Bool, acceptsScope: @escaping (FaceFileVersion) -> Bool,
         checkScope: @escaping () throws -> Void, mediaDate: @escaping (FaceFileVersion) -> FacePeopleAlbum.MediaDate? = { FacePeopleAlbum.date(captured: nil, modified: $0.modified) }) throws {
        index = try FaceIndexStore(directory: directory)
        store = FacePeopleStore(index: index)
        self.acceptsCurrent = acceptsCurrent; self.acceptsScope = acceptsScope; self.checkScope = checkScope
        self.mediaDate = mediaDate
        indexRevision = try index.revision(); peopleRevision = try store.revision()
    }
    private func valid(_ observation: IndexedFace) -> Bool {
        let key = Data(observation.file.path.utf8)
        if let found = currentFiles[key] { return found }
        let found = observation.model == FaceModels.modelID && acceptsCurrent(observation.file)
        currentFiles[key] = found
        return found
    }
    private func anchors() throws -> [String: Int64] {
        if let currentAnchors { return currentAnchors }
        var result: [String: Int64] = [:]
        try index.forEach(model: FaceModels.modelID) { observation in
            if valid(observation) {
                let anchor = FacePersonSnapshot(observation).anchor
                if !anchor.isEmpty { result[anchor] = observation.face.id }
            }
        }
        currentAnchors = result
        return result
    }
    private func savedID(_ annotation: FacePersonAnnotation) throws -> Int64? {
        if let value = savedIDs[annotation.anchor] { return value > 0 ? value : nil }
        let snapshot = annotation.snapshot
        let value = snapshot.model == FaceModels.modelID && acceptsCurrent(snapshot.file)
            ? try index.observationID(matching: snapshot) : nil
        savedIDs[annotation.anchor] = value ?? -1
        return value
    }
    private func current(_ id: Int64) throws -> IndexedFace {
        guard let face = try index.observations(model: FaceModels.modelID, id: id).first, valid(face) else {
            throw CLIError("This face changed or is outside the selected folders. Choose it again.")
        }
        return face
    }
    private func personID(_ request: [String: Any]) throws -> String {
        guard let id = request["person_id"] as? String, !id.isEmpty else { throw CLIError("Choose a person first.") }
        _ = try store.person(id)
        return id
    }
    private func number(_ request: [String: Any], _ key: String) -> Int64? {
        guard let value = request[key] as? NSNumber, String(cString: value.objCType) != "c",
              value.doubleValue.isFinite, value.doubleValue == Double(value.int64Value) else { return nil }
        return value.int64Value
    }
    private func threshold(_ request: [String: Any]) throws -> Double {
        let value = request["minimum_cosine"] as? Double ?? 0.363
        guard value.isFinite, (-1...1).contains(value) else { throw CLIError("Invalid face similarity threshold.") }
        return value
    }
    private func ids(_ request: [String: Any], _ key: String, max count: Int = 2000) throws -> [Int64] {
        guard let raw = request[key] else { return [] }
        guard let numbers = raw as? [NSNumber], numbers.count <= count,
              numbers.allSatisfy({ $0.int64Value > 0 && $0.doubleValue == Double($0.int64Value) }) else {
            throw CLIError("Invalid face selection. Select fewer faces or use all matching results.")
        }
        return Array(Set(numbers.map(\.int64Value))).sorted()
    }
    private func expired() -> [String: Any] { ["ok": false, "expired": true, "error": "People or face index changed. Refresh before continuing."] }
    private func assertStable() throws {
        try checkScope()
        guard try index.revision() == indexRevision, try store.revision() == peopleRevision else {
            throw FacePeopleStore.Failure("People or face index changed. Refresh before continuing.")
        }
    }
    private func stable() throws -> Bool {
        let currentIndex = try index.revision(), currentPeople = try store.revision()
        return currentIndex == indexRevision && currentPeople == peopleRevision
    }
    private func changeFields(_ change: FacePeopleChange) throws -> [String: Any] {
        ["ok": true, "changed": change.changed, "skipped_conflicts": change.conflicts, "skipped_stale": change.stale,
         "excluded": change.excluded, "operation_id": change.operationID as Any? ?? NSNull(),
         "people_revision": change.revision, "index_revision": try index.revision()]
    }
    private func referenceExamples(_ annotations: [FacePersonAnnotation]) throws -> FacePeopleReferences {
        var examples = FacePeopleReferences()
        for annotation in annotations where annotation.state == "assigned" {
            guard let id = try savedID(annotation), let observation = try index.observations(model: FaceModels.modelID, id: id).first else { continue }
            examples.add(observation.face.embedding)
        }
        return examples
    }
    func handle(_ op: String, _ request: [String: Any]) throws -> [String: Any] {
        switch op {
        case "person_save":
            guard let name = request["name"] as? String else { throw CLIError("Enter a person name.") }
            try checkScope()
            let (person, change) = try store.save(name: name, id: request["person_id"] as? String,
                                                   expected: number(request, "people_revision"))
            var result = try changeFields(change); result["person"] = ["id": person.id, "name": person.name]
            return result
        case "people_undo":
            guard let operation = request["operation_id"] as? String else { throw CLIError("Choose the latest People action to undo.") }
            return try changeFields(store.undo(operation, expectedPeople: number(request, "people_revision"),
                                              accepts: { [self] in acceptsScope($0.file) }, checkScope: checkScope))
        case "face_label": return try label(request)
        case "person_exclusion_preview", "person_exclude_similar": return try exclusion(op, request)
        case "person_exclude_file":
            let person = try personID(request)
            guard let faceID = number(request, "face_id"), faceID > 0, let expectedIndex = number(request, "index_revision"), expectedIndex >= 0,
                  let expectedPeople = number(request, "people_revision"), expectedPeople >= 0 else { throw CLIError("Refresh People before excluding this file.") }
            let source = try current(faceID)
            let before = try referenceExamples(store.annotations(person: person))
            let change = try store.excludeFile(person: person, file: source.file, expectedIndex: expectedIndex,
                expectedPeople: expectedPeople, accepts: acceptsCurrent, checkScope: checkScope)
            let after = try referenceExamples(store.annotations(person: person))
            var result = try changeFields(change)
            result["path"] = source.file.path
            result["reference_count_before"] = before.count; result["reference_count"] = after.count
            result["reference_source_count_before"] = before.sourceCount; result["reference_source_count"] = after.sourceCount
            return result
        case "people_list":
            let annotations = try store.annotations().filter { acceptsScope($0.snapshot.file) }
            var current: [String: Int64] = [:]
            for annotation in annotations { if let id = try savedID(annotation) { current[annotation.anchor] = id } }
            let grouped = Dictionary(grouping: annotations, by: \.personID)
            let query = request["q"] as? String ?? ""
            let people = try store.people().filter { FacePeopleStore.matches(name: $0.name, query: query) }.map { person -> [String: Any] in
                let own = grouped[person.id] ?? []
                return ["id": person.id, "name": person.name,
                        "assigned_count": own.filter { $0.state == "assigned" && current[$0.anchor] != nil }.count,
                        "assigned_file_count": Set(own.filter { $0.state == "assigned" && current[$0.anchor] != nil }.map { Data($0.snapshot.file.path.utf8) }).count,
                        "rejected_count": own.filter { $0.state == "rejected" && current[$0.anchor] != nil }.count,
                        "stale_count": own.filter { current[$0.anchor] == nil }.count, "suggestion_count": NSNull()]
            }
            guard try stable() else { return expired() }; try checkScope()
            return ["ok": true, "people": people, "people_revision": peopleRevision, "index_revision": indexRevision,
                    "undo_operation_id": try store.undoOperationID() as Any? ?? NSNull()]
        case "face_people":
            guard let id = number(request, "face_id") else { throw CLIError("Choose a face first.") }
            let face = try current(id), people = Dictionary(uniqueKeysWithValues: try store.people().map { ($0.id, $0) })
            let fields = try FaceService.labeledFields(face, store: store, people: people)
            guard try stable() else { return expired() }; try checkScope()
            return ["ok": true, "person": fields["person"] ?? NSNull(), "rejected_people": fields["rejected_people"] ?? [],
                    "anchor_key": fields["anchor_key"] ?? "", "people_revision": peopleRevision, "index_revision": indexRevision]
        case "person_faces": return try faces(request)
        default: throw CLIError("Unknown People operation.")
        }
    }
    private func exclusion(_ op: String, _ request: [String: Any]) throws -> [String: Any] {
        let person = try personID(request)
        guard let faceID = number(request, "face_id"), faceID > 0,
              let expectedIndex = number(request, "index_revision"), expectedIndex == indexRevision,
              let expectedPeople = number(request, "people_revision"), expectedPeople == peopleRevision else { return expired() }
        guard let raw = request["minimum_cosine"] as? NSNumber, String(cString: raw.objCType) != "c",
              raw.doubleValue.isFinite, (-1...1).contains(raw.doubleValue) else { throw CLIError("Invalid face similarity threshold.") }
        let minimum = raw.doubleValue, seed = try current(faceID)
        let annotations = try store.annotations(person: person)
        let rejected = Set(annotations.filter { $0.state == "rejected" }.map(\.anchor))
        var files: [Data: (face: IndexedFace, score: Double, count: Int)] = [:], observations = 0
        try store.forEachSimilar(to: seed, minimum: minimum, accepts: { [self] file in acceptsCurrent(file) }, checkScope: checkScope) { face, score in
            guard !rejected.contains(FacePersonSnapshot(face).anchor) else { return }
            observations += 1
            let key = Data(face.file.path.utf8), previous = files[key]
            let best = previous == nil || score > previous!.score || (score == previous!.score && face.face.id < previous!.face.face.id)
            files[key] = (best ? face : previous!.face, best ? score : previous!.score, (previous?.count ?? 0) + 1)
        }
        try assertStable()
        if op == "person_exclude_similar" {
            let before = try referenceExamples(annotations)
            let change = try store.excludeSimilar(person: person, seed: seed, minimum: minimum,
                expectedIndex: expectedIndex, expectedPeople: expectedPeople, accepts: acceptsCurrent, checkScope: checkScope)
            let after = try referenceExamples(store.annotations(person: person))
            var result = try changeFields(change)
            result["matched_file_count"] = files.count; result["matched_observation_count"] = observations
            result["reference_count_before"] = before.count; result["reference_count"] = after.count
            result["reference_source_count_before"] = before.sourceCount; result["reference_source_count"] = after.sourceCount
            return result
        }
        let ranked = files.values.sorted { $0.score == $1.score ? $0.face.face.id < $1.face.face.id : $0.score > $1.score }
        let offset = max(0, number(request, "offset") ?? 0), limit = min(100, max(1, number(request, "limit") ?? 40))
        let start = min(Int(clamping: offset), ranked.count), next = min(ranked.count, start + Int(limit))
        let names = Dictionary(uniqueKeysWithValues: try store.people().map { ($0.id, $0) })
        let hits = try ranked[start..<next].map { item -> [String: Any] in
            var fields = try FaceService.labeledFields(item.face, store: store, people: names)
            fields["cosine"] = item.score; fields["observation_count"] = item.count
            return fields
        }
        try assertStable()
        return ["ok": true, "hits": hits, "total": ranked.count, "observation_count": observations,
                "next_offset": next, "has_more": next < ranked.count, "minimum_cosine": minimum,
                "index_revision": indexRevision, "people_revision": peopleRevision]
    }
    private func label(_ request: [String: Any]) throws -> [String: Any] {
        let person = try personID(request)
        guard let action = request["action"] as? String, let expectedIndex = number(request, "index_revision") else {
            throw CLIError("Refresh the face results before assigning or rejecting them.")
        }
        let chosen = try ids(request, "face_ids"), excluded = Set(try ids(request, "exclude_face_ids", max: 100_000))
        let seedID = number(request, "seed_face_id"), includeSeed = request["include_seed"] as? Bool ?? true
        let removal = request["anchor_keys"] as? [String] ?? []
        guard removal.count <= 2000, removal.allSatisfy({ $0.count == 64 }), seedID == nil || chosen.isEmpty,
              !chosen.isEmpty || seedID != nil || !removal.isEmpty else { throw CLIError("Choose faces to change.") }
        let seed = try seedID.map(current), minimum = try threshold(request)
        var missing = 0
        let change = try store.label(person: person, action: action, expectedIndex: expectedIndex,
            expectedPeople: number(request, "people_revision"), exclusions: excluded, removeAnchors: removal,
            respectRejections: seedID != nil,
            accepts: acceptsCurrent, acceptsStaleAnchor: acceptsScope, checkScope: checkScope) { [self] consume in
                if let seed {
                    try index.forEach(model: FaceModels.modelID) { observation in
                        guard acceptsScope(observation.file) else { return }
                        let own = observation.face.id == seed.face.id
                        guard (own && includeSeed) || (!own && (FaceIndexStore.cosine(seed.face.embedding, observation.face.embedding) ?? -2) >= minimum) else { return }
                        try consume(observation)
                    }
                } else {
                    for id in chosen {
                        guard let observation = try index.observations(model: FaceModels.modelID, id: id).first else { missing += 1; continue }
                        try consume(observation)
                    }
                }
            }
        var result = try changeFields(change)
        result["skipped_stale"] = change.stale + missing
        return result
    }
    private func faces(_ request: [String: Any]) throws -> [String: Any] {
        let id = try personID(request), person = try store.person(id), mode = request["mode"] as? String ?? "assigned"
        guard ["gallery", "assigned", "suggestions", "rejected", "stale"].contains(mode) else { throw CLIError("Choose a person gallery, assigned faces, suggestions, rejected faces or stale annotations.") }
        let offset = max(0, request["offset"] as? Int ?? 0), limit = min(max(1, request["limit"] as? Int ?? 40), 200)
        if offset > 0, number(request, "index_revision") != indexRevision || number(request, "people_revision") != peopleRevision { return expired() }
        // Opening an assigned album is a saved-label lookup, not a face search. Only suggestions need the
        // global descriptor scan. Even the directory counts inspect labelled observations rather than the corpus.
        let all = mode == "suggestions" ? try store.annotations() : try store.annotations(person: id)
        let own = all.filter { $0.personID == id && acceptsScope($0.snapshot.file) }
        var current: [String: Int64] = [:]
        if mode == "suggestions" { current = try anchors() }
        else { for annotation in own { if let faceID = try savedID(annotation) { current[annotation.anchor] = faceID } } }
        var counts = ["assigned": own.filter { $0.state == "assigned" && current[$0.anchor] != nil }.count,
                      "assigned_files": Set(own.filter { $0.state == "assigned" && current[$0.anchor] != nil }.map { Data($0.snapshot.file.path.utf8) }).count,
                      "rejected": own.filter { $0.state == "rejected" && current[$0.anchor] != nil }.count,
                      "stale": own.filter { current[$0.anchor] == nil }.count, "suggestions": 0]
        var ranked: [(id: Int64, cosine: Double?)] = []
        var stale: [FacePersonAnnotation] = []
        var references = FacePeopleReferences()
        var fileObservationCounts: [Int64: Int] = [:]
        var galleryOrder = FacePeopleAlbum.Order.indexed, galleryMedia = FacePeopleAlbum.Media.all
        var galleryDates: [Data: FacePeopleAlbum.MediaDate] = [:]
        var galleryPeriod: FacePeopleAlbum.Period?
        let minimum = try threshold(request)
        if mode == "gallery" {
            guard let order = FacePeopleAlbum.Order(rawValue: request["gallery_sort"] as? String ?? "indexed"),
                  let media = FacePeopleAlbum.Media(rawValue: request["gallery_media"] as? String ?? "all") else {
                throw CLIError("Choose a valid gallery sort and media filter.")
            }
            galleryOrder = order; galleryMedia = media
            func year(_ key: String) throws -> Int? {
                guard let value = request[key], !(value is NSNull) else { return nil }
                guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
                      number.doubleValue.isFinite, number.doubleValue == Double(number.intValue), (1...9999).contains(number.intValue) else {
                    throw CLIError("Choose a valid year from 1 to 9999.")
                }
                return number.intValue
            }
            do { galleryPeriod = try FacePeopleAlbum.Period(from: year("gallery_from_year"), through: year("gallery_through_year")) }
            catch { throw CLIError("Choose a valid year range: the first year must not exceed the last.") }
            for annotation in own where annotation.state == "assigned" && current[annotation.anchor] != nil {
                let file = annotation.snapshot.file, key = Data(file.path.utf8)
                if galleryDates[key] == nil { galleryDates[key] = mediaDate(file) }
            }
            let files = FacePeopleAlbum.files(own.filter { $0.state == "assigned" }.compactMap { annotation in
                current[annotation.anchor].map { (id: $0, path: annotation.snapshot.file.path,
                    kind: annotation.snapshot.file.kind, modified: annotation.snapshot.file.modified) }
            }, order: order, media: media, dates: galleryDates, period: galleryPeriod)
            ranked = files.map { ($0.representativeID, nil) }
            fileObservationCounts = Dictionary(uniqueKeysWithValues: files.map { ($0.representativeID, $0.observationCount) })
        } else if mode == "suggestions" {
            // A bounded deterministic sample spans confirmed descriptors instead of taking the first video frames.
            // Every retained example is explicitly confirmed; candidate suggestions never become references.
            references = try referenceExamples(own)
            let unavailable = Set(all.filter { $0.state == "assigned" || ($0.personID == id && $0.state == "rejected") }.map(\.anchor))
            if references.count > 0 {
                try index.forEach(model: FaceModels.modelID) { observation in
                    guard valid(observation), !unavailable.contains(FacePersonSnapshot(observation).anchor) else { return }
                    let score = references.score(observation.face.embedding) ?? -2
                    if score >= minimum { ranked.append((observation.face.id, score)) }
                }
            }
            ranked.sort { $0.cosine == $1.cosine ? $0.id < $1.id : ($0.cosine ?? -2) > ($1.cosine ?? -2) }
            counts["suggestions"] = ranked.count
        } else if mode == "stale" {
            stale = own.filter { current[$0.anchor] == nil }
        } else {
            ranked = own.filter { $0.state == mode }.compactMap { annotation in current[annotation.anchor].map { ($0, nil) } }
            ranked.sort { $0.id < $1.id }
        }
        let total = mode == "stale" ? stale.count : ranked.count, start = min(offset, total), next = min(total, start + limit)
        let names = Dictionary(uniqueKeysWithValues: try store.people().map { ($0.id, $0) })
        var hits: [[String: Any]] = []
        if mode == "stale" {
            for annotation in stale[start..<next] {
                let s = annotation.snapshot
                hits.append(["id": "stale:\(annotation.anchor)", "face_id": NSNull(), "anchor_key": annotation.anchor,
                    "path": s.file.path, "kind": s.file.kind, "size": s.file.size, "modified": s.file.modified,
                    "bbox": s.bbox, "landmarks": s.landmarks, "quality": s.score, "loc": s.loc as Any? ?? NSNull(), "model_id": s.model,
                    "person_status": "stale", "annotation_status": annotation.state, "stale": true, "preview_allowed": false])
            }
        } else {
            for item in ranked[start..<next] {
                let observation = try self.current(item.id)
                var fields = try FaceService.labeledFields(observation, store: store, people: names)
                fields["person_status"] = mode == "suggestions" ? "suggestion" : mode
                fields["name"] = (observation.file.path as NSString).lastPathComponent
                if let count = fileObservationCounts[item.id] { fields["observation_count"] = count }
                if let date = galleryDates[Data(observation.file.path.utf8)] {
                    fields["gallery_date"] = date.day; fields["gallery_date_source"] = date.source
                    fields["gallery_timestamp"] = date.sortKey
                }
                if let score = item.cosine { fields["cosine"] = score; fields["score"] = score }
                hits.append(fields)
            }
        }
        guard try stable() else { return expired() }; try checkScope()
        var result: [String: Any] = ["ok": true, "person": ["id": person.id, "name": person.name], "hits": hits, "counts": counts, "total": total,
                "next_offset": next, "has_more": next < total, "mode": mode, "minimum_cosine": minimum,
                "index_revision": indexRevision, "people_revision": peopleRevision,
                "reference_count": references.count, "reference_limit": FacePeopleReferences.limit,
                "reference_source_count": references.sourceCount, "references_sampled": references.sampled]
        if mode == "gallery" {
            result["gallery_sort"] = galleryOrder.rawValue; result["gallery_media"] = galleryMedia.rawValue
            result["gallery_from_year"] = galleryPeriod?.from as Any? ?? NSNull()
            result["gallery_through_year"] = galleryPeriod?.through as Any? ?? NSNull()
            result["gallery_year_min"] = galleryDates.values.map(\.year).min() as Any? ?? NSNull()
            result["gallery_year_max"] = galleryDates.values.map(\.year).max() as Any? ?? NSNull()
        }
        return result
    }
}

extension FaceService {
    /// Lightweight polling: only revision metadata is read here. The semantic-file map, template collection and
    /// comparisons are made once per key on the cache's private queue, alongside indexing and ordinary search.
    func suggestions(_ request: [String: Any]) throws -> [String: Any] {
        let minimum = request["minimum_cosine"] as? Double ?? 0.363
        guard minimum.isFinite, (-1...1).contains(minimum) else { throw CLIError("Invalid face similarity threshold.") }
        let context = suggestionContext()
        let faceDatabase = context.directory.appendingPathComponent(FaceIndexStore.name)
        let exists = FileManager.default.fileExists(atPath: faceDatabase.path)
        var indexRevision: Int64 = 0, peopleRevision: Int64 = 0
        if exists {
            let metadata = try Database(path: faceDatabase.path)
            try metadata.query("SELECT key,value FROM face_meta WHERE key IN ('revision','people_revision')") { row in
                if row.text(0) == "revision" { indexRevision = row.int(1) }
                else if row.text(0) == "people_revision" { peopleRevision = row.int(1) }
            }
        }
        let key = FaceSuggestionSummaryKey(scopeRevision: context.revision, indexRevision: indexRevision,
            peopleRevision: peopleRevision, sourceRevision: context.sourceRevision, minimumCosine: minimum)
        let snapshot = suggestionSummary.request(key: key, refresh: request["refresh"] as? Bool ?? false) { [self] token in
            try token.check()
            try checkSuggestionScope(context.revision, sourceRevision: context.sourceRevision)
            guard exists else { return FaceSuggestionSummary(key: key, people: []) }
            let main = try Database(path: context.directory.appendingPathComponent(IndexStore.mainFile).path)
            var indexed: [Data: FaceFileVersion] = [:]
            try main.query("SELECT path,kind,size,mtime FROM files WHERE kind IN ('image','screenshot','video') AND state IN ('done','partial')") { row in
                try token.check()
                guard let path = row.text(0), let kind = row.text(1) else { return }
                indexed[Data(path.utf8)] = FaceFileVersion(path: path, kind: kind, size: row.int(2), modified: row.double(3))
            }
            let index = try FaceIndexStore(directory: context.directory)
            return try FaceSuggestionSummary.calculate(index: index, key: key, cancellation: token, acceptsCurrent: { file in
                indexed[Data(file.path.utf8)] == file && Self.current(file, scope: context.scope)
            }, acceptsScope: { file in
                context.scope.accepts(file.path) && context.scope.accepts(FolderSelection.realPath(file.path))
            }, checkScope: { [self] in try checkSuggestionScope(context.revision, sourceRevision: context.sourceRevision) })
        }
        try checkSuggestionScope(context.revision, sourceRevision: context.sourceRevision)
        let rows: [[String: Any]] = snapshot.result?.people.map { person in
            ["person_id": person.personID, "name": person.name, "pending_count": person.pendingCount,
             "reference_count": person.referenceCount, "reference_source_count": person.referenceSourceCount,
             "references_sampled": person.referencesSampled]
        } ?? []
        return ["ok": true, "state": snapshot.state.rawValue, "total": snapshot.result.map { $0.total } as Any? ?? NSNull(),
                "people": rows, "index_revision": indexRevision, "people_revision": peopleRevision,
                "scope_revision": context.revision, "source_revision": context.sourceRevision, "minimum_cosine": minimum,
                "count_unit": "person_observation_pairs", "reference_limit": FacePeopleReferences.limit,
                "observations_checked": snapshot.result.map { $0.observationsChecked } as Any? ?? NSNull(),
                "computed_at": snapshot.result.map { $0.computedAt } as Any? ?? NSNull(), "error": snapshot.error as Any? ?? NSNull()]
    }
}
