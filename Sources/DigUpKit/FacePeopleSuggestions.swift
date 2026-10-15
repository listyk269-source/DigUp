import Foundation

public struct FaceSuggestionSummaryKey: Hashable, Sendable {
    public let scopeRevision: UInt64
    public let sourceRevision: UInt64
    public let indexRevision: Int64
    public let peopleRevision: Int64
    public let minimumCosine: Double
    public let modelID: String
    public init(scopeRevision: UInt64, indexRevision: Int64, peopleRevision: Int64, sourceRevision: UInt64 = 0,
                minimumCosine: Double = 0.363, modelID: String = FaceModels.modelID) {
        self.scopeRevision = scopeRevision; self.sourceRevision = sourceRevision
        self.indexRevision = indexRevision; self.peopleRevision = peopleRevision
        self.minimumCosine = minimumCosine; self.modelID = modelID
    }
}

public struct FaceSuggestionPersonCount: Sendable, Equatable {
    public let personID: String
    public let name: String
    public let pendingCount: Int
    public let referenceCount: Int
    public let referenceSourceCount: Int
    public let referencesSampled: Bool
}

/// Counts person-observation pairs, not distinct identities/files. One unassigned observation can be a candidate
/// for two manually named people. No proposal is written to the annotation tables or used as a reference.
public struct FaceSuggestionSummary: Sendable, Equatable {
    public let key: FaceSuggestionSummaryKey
    public let people: [FaceSuggestionPersonCount]
    public let total: Int
    public let observationsChecked: Int
    public let computedAt: Double
    public init(key: FaceSuggestionSummaryKey, people: [FaceSuggestionPersonCount], observationsChecked: Int = 0) {
        self.key = key; self.people = people; total = people.reduce(0) { $0 + $1.pendingCount }
        self.observationsChecked = observationsChecked; computedAt = Date().timeIntervalSince1970
    }

    public static func calculate(index: FaceIndexStore, key: FaceSuggestionSummaryKey, cancellation: FaceCancellation,
                                 acceptsCurrent: @escaping (FaceFileVersion) -> Bool,
                                 acceptsScope: @escaping (FaceFileVersion) -> Bool,
                                 checkScope: () throws -> Void) throws -> FaceSuggestionSummary {
        let store = FacePeopleStore(index: index)
        func check() throws {
            try cancellation.check()
            do { try checkScope() } catch { throw CancellationError() }
            guard try index.revision() == key.indexRevision, try store.revision() == key.peopleRevision else { throw CancellationError() }
        }
        try check()
        guard key.minimumCosine.isFinite, (-1...1).contains(key.minimumCosine), key.modelID == FaceModels.modelID else {
            throw FacePeopleStore.Failure("The suggestion model or similarity threshold is invalid.")
        }
        let people = try store.people(), names = Set(people.map(\.id))
        var assigned: [String: String] = [:], rejected: [String: Set<String>] = [:]
        var scopePaths: [Data: Bool] = [:]
        var scanned = 0
        try store.forEachAnnotation { annotation in
            scanned += 1
            if scanned % 64 == 0 { try check() }
            let path = Data(annotation.snapshot.file.path.utf8)
            let inScope = scopePaths[path] ?? acceptsScope(annotation.snapshot.file)
            scopePaths[path] = inScope
            guard inScope, names.contains(annotation.personID) else { return }
            if annotation.state == "assigned" { assigned[annotation.anchor] = annotation.personID }
            else if annotation.state == "rejected" { rejected[annotation.anchor, default: []].insert(annotation.personID) }
        }
        var references: [String: FacePeopleReferences] = [:]
        var validPaths: [Data: Bool] = [:], checkedFiles: [Data: FaceFileVersion] = [:]
        func valid(_ observation: IndexedFace) -> Bool {
            let path = Data(observation.file.path.utf8)
            if let cached = validPaths[path] { return cached }
            let found = observation.model == key.modelID && acceptsCurrent(observation.file)
            validPaths[path] = found
            if found { checkedFiles[path] = observation.file }
            return found
        }
        if !assigned.isEmpty {
            try index.forEach(model: key.modelID) { observation in
                scanned += 1
                if scanned % 64 == 0 { try check() }
                guard valid(observation), let person = assigned[FacePersonSnapshot(observation).anchor] else { return }
                references[person, default: FacePeopleReferences()].add(observation.face.embedding)
            }
        }
        try check()
        var counts: [String: Int] = [:], observationsChecked = 0
        if !references.isEmpty {
            let active = references.sorted { $0.key < $1.key }
            try index.forEach(model: key.modelID) { observation in
                scanned += 1
                if scanned % 64 == 0 { try check() }
                guard valid(observation) else { return }
                observationsChecked += 1
                let anchor = FacePersonSnapshot(observation).anchor
                guard assigned[anchor] == nil else { return }
                let excluded = rejected[anchor] ?? []
                for (person, examples) in active {
                    try cancellation.check()
                    guard !excluded.contains(person), (examples.score(observation.face.embedding) ?? -2) >= key.minimumCosine else { continue }
                    counts[person, default: 0] += 1
                }
            }
        }
        // A document can change on disk before the normal scanner publishes its metadata update. Never publish
        // a freshly calculated count from file versions which stopped being current during this computation.
        for file in checkedFiles.values {
            try cancellation.check()
            guard acceptsCurrent(file) else { throw CancellationError() }
        }
        try check()
        return FaceSuggestionSummary(key: key, people: people.map { person in
            let examples = references[person.id] ?? FacePeopleReferences()
            return FaceSuggestionPersonCount(personID: person.id, name: person.name, pendingCount: counts[person.id] ?? 0,
                referenceCount: examples.count, referenceSourceCount: examples.sourceCount, referencesSampled: examples.sampled)
        }, observationsChecked: observationsChecked)
    }
}

public enum FaceSuggestionSummaryState: String, Sendable { case idle, computing, ready, error }
public struct FaceSuggestionSummarySnapshot: Sendable {
    public let state: FaceSuggestionSummaryState
    public let key: FaceSuggestionSummaryKey?
    public let result: FaceSuggestionSummary?
    public let error: String?
}

/// A single revision-keyed cache, with a private utility queue. Polls never rank faces or queue duplicate work.
/// Scope/revision changes cancel obsolete scans; a late result cannot replace a newer key's result.
public final class FaceSuggestionSummaryCache: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "DigUp.people-suggestion-summary", qos: .utility)
    private var generation: UInt64 = 0
    private var key: FaceSuggestionSummaryKey?
    private var state = FaceSuggestionSummaryState.idle
    private var result: FaceSuggestionSummary?
    private var message: String?
    private var cancellation: FaceCancellation?
    public init() {}
    private func snapshot() -> FaceSuggestionSummarySnapshot {
        FaceSuggestionSummarySnapshot(state: state, key: key, result: result, error: message)
    }
    @discardableResult public func request(key requested: FaceSuggestionSummaryKey, refresh: Bool = false,
        build: @escaping @Sendable (FaceCancellation) throws -> FaceSuggestionSummary) -> FaceSuggestionSummarySnapshot {
        lock.withLock {
            if !refresh, key == requested, state != .idle { return snapshot() }
            generation &+= 1
            let selected = generation, token = FaceCancellation()
            cancellation?.cancel(); cancellation = token
            key = requested; result = nil; message = nil; state = .computing
            queue.async { [self] in
                do {
                    try token.check()
                    let completed = try build(token)
                    try token.check()
                    lock.withLock {
                        guard generation == selected, key == requested else { return }
                        guard completed.key == requested else { state = .idle; result = nil; return }
                        result = completed; state = .ready; cancellation = nil
                    }
                } catch is CancellationError {
                    lock.withLock {
                        guard generation == selected else { return }
                        state = .idle; result = nil; cancellation = nil
                    }
                } catch {
                    lock.withLock {
                        guard generation == selected else { return }
                        state = .error; result = nil; cancellation = nil
                        message = "Suggestion counts could not be updated. Refresh People to retry."
                    }
                }
            }
            return snapshot()
        }
    }
    public func cancel() {
        lock.withLock {
            generation &+= 1; cancellation?.cancel(); cancellation = nil
            key = nil; state = .idle; result = nil; message = nil
        }
    }
    public func invalidate() { cancel() }
}
