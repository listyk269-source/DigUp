import Foundation
import Testing
@testable import DigUpKit

@Suite struct FaceSuggestionSummaryTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-suggestion-summary-\(UUID().uuidString)") }
    private func add(_ index: FaceIndexStore, _ number: Int, x: Float = 1, path: String? = nil,
                     modified: Double = 1, model: String = FaceModels.modelID) throws -> IndexedFace {
        var vector = [Float](repeating: 0, count: 128); vector[0] = x; vector[1] = sqrt(1 - x * x)
        let observation = FaceObservation(bbox: [0.1, 0.2, 0.3, 0.4], landmarks: [0.2, 0.3, 0.3, 0.3, 0.25, 0.4, 0.2, 0.5, 0.3, 0.5],
            score: 0.99, embedding: vector, loc: nil)
        let file = FaceFileVersion(path: path ?? "/scope/Фото 🦊 \(number).jpg", kind: "image", size: 100, modified: modified)
        try index.replace(file, model: model, config: "test", frames: 1, faces: [observation])
        return try #require(index.observations(path: file.path).first)
    }
    private func key(_ index: FaceIndexStore, threshold: Double = 0.5, scope: UInt64 = 1,
                     source: UInt64 = 1) throws -> FaceSuggestionSummaryKey {
        FaceSuggestionSummaryKey(scopeRevision: scope, indexRevision: try index.revision(),
            peopleRevision: try FacePeopleStore(index: index).revision(), sourceRevision: source, minimumCosine: threshold)
    }
    private func calculate(_ index: FaceIndexStore) throws -> FaceSuggestionSummary {
        try FaceSuggestionSummary.calculate(index: index, key: key(index), cancellation: FaceCancellation(),
            acceptsCurrent: { $0.path.hasPrefix("/scope/") && $0.modified == 1 },
            acceptsScope: { $0.path.hasPrefix("/scope/") }, checkScope: {})
    }
    private func label(_ store: FacePeopleStore, _ person: String, _ face: IndexedFace, _ action: String = "assign") throws {
        _ = try store.label(person: person, action: action, expectedIndex: store.index.revision(), accepts: { _ in true }) { try $0(face) }
    }
    @Test func pairCountsRespectManualReferencesRejectionsScopeVersionsAndModel() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index)
        let a = try store.save(name: "Анна").0, b = try store.save(name: "Борис").0
        let noReferences = try store.save(name: "Без примеров").0, stalePerson = try store.save(name: "Старый пример").0
        let seedA = try add(index, 1), seedB = try add(index, 2, x: 0.8)
        let pending = try add(index, 3, x: 0.9), rejectedA = try add(index, 4, x: 0.95)
        let stale = try add(index, 5, modified: 2)
        _ = try add(index, 6, path: "/outside/Лицо.jpg")
        _ = try add(index, 7, model: "incompatible-face-model")
        try label(store, a.id, seedA); try label(store, b.id, seedB)
        try label(store, a.id, rejectedA, "reject"); try label(store, stalePerson.id, stale)
        let before = try store.annotations().count
        let result = try calculate(index)
        let counts = Dictionary(uniqueKeysWithValues: result.people.map { ($0.personID, $0.pendingCount) })
        #expect(counts[a.id] == 1 && counts[b.id] == 2)
        #expect(counts[noReferences.id] == 0 && counts[stalePerson.id] == 0)
        #expect(result.total == 3) // Two observations; one is proposed to two named people.
        #expect(result.observationsChecked == 4)
        #expect(try store.annotations().count == before)
        #expect(try store.annotations(anchor: FacePersonSnapshot(pending).anchor).isEmpty)
    }
    @Test func assignmentRejectionUndoAndNewFilesRecomputeWithoutAccumulation() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index)
        let person = try store.save(name: "Человек").0, seed = try add(index, 1), target = try add(index, 2)
        try label(store, person.id, seed)
        #expect(try calculate(index).total == 1)
        let rejection = try store.label(person: person.id, action: "reject", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(target) }
        #expect(try calculate(index).total == 0)
        _ = try store.undo(#require(rejection.operationID))
        #expect(try calculate(index).total == 1)
        _ = try add(index, 1) // A new face ID for the same confirmed observation keeps its exact anchor.
        #expect(try calculate(index).total == 1)
        _ = try add(index, 3)
        #expect(try calculate(index).total == 2)
        _ = try add(index, 3)
        #expect(try calculate(index).total == 2)
        try label(store, person.id, target)
        #expect(try calculate(index).total == 1)
        let third = try #require(index.observations().first { $0.file.path.hasSuffix("3.jpg") })
        try index.removeDeleted(retainedPaths: Set(try index.observations().filter { $0.face.id != third.face.id }.map { Data($0.file.path.utf8) }))
        #expect(try calculate(index).total == 0)
    }
    @Test func incompatibleRevisionsScopeAndCancellationNeverProduceCounts() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory)
        let original = try key(index)
        _ = try add(index, 1)
        #expect(throws: CancellationError.self) {
            try FaceSuggestionSummary.calculate(index: index, key: original, cancellation: FaceCancellation(),
                acceptsCurrent: { _ in true }, acceptsScope: { _ in true }, checkScope: {})
        }
        let cancelled = FaceCancellation(); cancelled.cancel()
        #expect(throws: CancellationError.self) {
            try FaceSuggestionSummary.calculate(index: index, key: key(index), cancellation: cancelled,
                acceptsCurrent: { _ in true }, acceptsScope: { _ in true }, checkScope: {})
        }
        #expect(throws: CancellationError.self) {
            try FaceSuggestionSummary.calculate(index: index, key: key(index), cancellation: FaceCancellation(),
                acceptsCurrent: { _ in true }, acceptsScope: { _ in true }, checkScope: { throw FacePeopleStore.Failure("scope changed") })
        }
    }
    @Test func fileChangingDuringCalculationPreventsPublication() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index)
        let person = try store.save(name: "Человек").0, seed = try add(index, 1)
        _ = try add(index, 2); try label(store, person.id, seed)
        var visits: [Data: Int] = [:]
        #expect(throws: CancellationError.self) {
            try FaceSuggestionSummary.calculate(index: index, key: key(index), cancellation: FaceCancellation(), acceptsCurrent: { file in
                let path = Data(file.path.utf8); visits[path, default: 0] += 1
                return visits[path] == 1
            }, acceptsScope: { _ in true }, checkScope: {})
        }
    }
    private func ready(_ cache: FaceSuggestionSummaryCache, _ key: FaceSuggestionSummaryKey,
                       build: @escaping @Sendable (FaceCancellation) throws -> FaceSuggestionSummary) throws -> FaceSuggestionSummarySnapshot {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            let found = cache.request(key: key, build: build)
            if found.state == .ready || found.state == .error { return found }
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw FacePeopleStore.Failure("The unit-test suggestion worker did not finish.")
    }
    @Test func unchangedPollsReuseOneCalculationAndCountDoesNotGrow() throws {
        let cache = FaceSuggestionSummaryCache(), calls = SummaryTestCounter()
        defer { cache.cancel() }
        let key = FaceSuggestionSummaryKey(scopeRevision: 1, indexRevision: 2, peopleRevision: 3, minimumCosine: 0.5)
        let build: @Sendable (FaceCancellation) throws -> FaceSuggestionSummary = { _ in calls.add(); return FaceSuggestionSummary(key: key, people: []) }
        let first = try ready(cache, key, build: build)
        for _ in 0..<100 { #expect(cache.request(key: key, build: build).result?.total == first.result?.total) }
        #expect(calls.value == 1)
        #expect(first.result?.computedAt == cache.request(key: key, build: build).result?.computedAt)
    }
    @Test func obsoleteBuildCannotOverwriteNewScopeOrRevision() throws {
        let cache = FaceSuggestionSummaryCache(), started = DispatchSemaphore(value: 0)
        defer { cache.cancel() }
        let old = FaceSuggestionSummaryKey(scopeRevision: 1, indexRevision: 1, peopleRevision: 1)
        _ = cache.request(key: old) { token in
            started.signal()
            let deadline = Date().addingTimeInterval(2)
            while !token.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            return FaceSuggestionSummary(key: old, people: [])
        }
        #expect(started.wait(timeout: .now() + 2) == .success)
        let latest = FaceSuggestionSummaryKey(scopeRevision: 2, indexRevision: 3, peopleRevision: 4, sourceRevision: 5)
        let found = try ready(cache, latest) { _ in FaceSuggestionSummary(key: latest, people: []) }
        #expect(found.state == .ready && found.result?.key == latest)
        #expect(latest != FaceSuggestionSummaryKey(scopeRevision: 2, indexRevision: 3, peopleRevision: 4, sourceRevision: 6))
        #expect(latest != FaceSuggestionSummaryKey(scopeRevision: 2, indexRevision: 3, peopleRevision: 4, sourceRevision: 5, minimumCosine: 0.5))
    }
    @Test func failedWorkIsCachedUntilExplicitRefresh() throws {
        let cache = FaceSuggestionSummaryCache(), calls = SummaryTestCounter()
        defer { cache.cancel() }
        let key = FaceSuggestionSummaryKey(scopeRevision: 1, indexRevision: 1, peopleRevision: 1)
        let failed: @Sendable (FaceCancellation) throws -> FaceSuggestionSummary = { _ in calls.add(); throw FacePeopleStore.Failure("test failure") }
        let error = try ready(cache, key, build: failed)
        #expect(error.state == .error && error.result == nil)
        for _ in 0..<20 { _ = cache.request(key: key, build: failed) }
        #expect(calls.value == 1)
        let good: @Sendable (FaceCancellation) throws -> FaceSuggestionSummary = { _ in calls.add(); return FaceSuggestionSummary(key: key, people: []) }
        _ = cache.request(key: key, refresh: true, build: good)
        #expect(try ready(cache, key, build: good).state == .ready)
        #expect(calls.value == 2)
    }
    @Test func completedWorkWithWrongRevisionCannotPublishItsOldCount() throws {
        let cache = FaceSuggestionSummaryCache(), calls = SummaryTestCounter()
        defer { cache.cancel() }
        let expected = FaceSuggestionSummaryKey(scopeRevision: 1, indexRevision: 2, peopleRevision: 3)
        let wrong = FaceSuggestionSummaryKey(scopeRevision: 1, indexRevision: 2, peopleRevision: 2)
        _ = cache.request(key: expected) { _ in
            calls.add()
            return FaceSuggestionSummary(key: wrong, people: [FaceSuggestionPersonCount(personID: "old", name: "Old",
                pendingCount: 999, referenceCount: 1, referenceSourceCount: 1, referencesSampled: false)])
        }
        let found = try ready(cache, expected) { _ in calls.add(); return FaceSuggestionSummary(key: expected, people: []) }
        #expect(found.result?.key == expected && found.result?.total == 0)
        #expect(calls.value == 2)
    }
}

private final class SummaryTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
