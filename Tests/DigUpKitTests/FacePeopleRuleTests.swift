import Foundation
import Testing
@testable import DigUpKit

@Suite struct FacePeopleRuleTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func add(_ index: FaceIndexStore, _ path: String, _ angle: Double, time: Double? = nil) throws -> IndexedFace {
        var vector = [Float](repeating: 0, count: 128); vector[0] = Float(cos(angle)); vector[1] = Float(sin(angle))
        let face = FaceObservation(bbox: [0.1, 0.2, 0.2, 0.3], landmarks: [0.2, 0.3, 0.3, 0.3, 0.25, 0.4, 0.2, 0.5, 0.3, 0.5], score: 0.98, embedding: vector, loc: time)
        try index.replace(FaceFileVersion(path: path, kind: time == nil ? "image" : "video", size: 100, modified: 1), model: FaceModels.modelID, config: "unit", frames: 1, faces: [face])
        return try #require(index.observations(path: path).first)
    }
    private func assign(_ store: FacePeopleStore, _ person: String, _ face: IndexedFace) throws {
        _ = try store.label(person: person, action: "assign", expectedIndex: store.index.revision(), accepts: { _ in true }) { try $0(face) }
    }
    private func count(_ index: FaceIndexStore, _ person: String) throws -> Int {
        let store = FacePeopleStore(index: index)
        let result = try FaceSuggestionSummary.calculate(index: index,
            key: FaceSuggestionSummaryKey(scopeRevision: 1, indexRevision: index.revision(), peopleRevision: store.revision(), minimumCosine: 0.5),
            cancellation: FaceCancellation(), acceptsCurrent: { _ in true }, acceptsScope: { _ in true }, checkScope: {})
        return try #require(result.people.first { $0.personID == person }).pendingCount
    }
    @Test func newPhotosAndVideoFramesAreSuppressedForOnlyTheChosenPersonAfterRestartAndSourceDeletion() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var person = "", other = ""
        do {
            let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index)
            person = try store.save(name: "Человек").0.id; other = try store.save(name: "Другой").0.id
            try assign(store, person, add(index, "/Фото/Верный.jpg", 0))
            let wrong = try add(index, "/Фото/Ошибка Ё café.jpg", 0.8)
            _ = try store.excludeSimilar(person: person, seed: wrong, minimum: 0.95, expectedIndex: index.revision(), expectedPeople: store.revision(), accepts: { _ in true })
            #expect(try store.exclusionRules(person: person).count == 1)
        }
        let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index)
        try assign(store, other, add(index, "/Фото/Образец другого.jpg", 0.8))
        _ = try add(index, "/Фото/Новый снимок.jpg", 0.75)
        _ = try add(index, "/Фото/Новое видео.mp4", 0.82, time: 12)
        _ = try add(index, "/Фото/Верное предложение.jpg", 0.1)
        try index.removeDeleted(retainedPaths: Set(try index.observations().filter { !$0.file.path.contains("Ошибка") }.map { Data($0.file.path.utf8) }))
        #expect(try count(index, person) == 1)
        #expect(try count(index, other) == 3)
        let rule = try #require(store.exclusionRules(person: person).first)
        let removal = try store.removeExclusionRule(rule.id, person: person, expectedPeople: store.revision())
        #expect(try count(index, person) == 3)
        _ = try store.undo(#require(removal.operationID)); #expect(try count(index, person) == 1)
    }
    @Test func exclusionAndRuleAreOneUndoOperationAndExplicitAssignmentsStillWork() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index)
        let person = try store.save(name: "Человек").0.id
        try assign(store, person, add(index, "/Фото/Верный.jpg", 0))
        let wrong = try add(index, "/Фото/Ошибка.jpg", 0.8)
        let change = try store.excludeSimilar(person: person, seed: wrong, minimum: 0.95, expectedIndex: index.revision(), expectedPeople: store.revision(), accepts: { _ in true })
        _ = try add(index, "/Фото/Новое.jpg", 0.8)
        #expect(try count(index, person) == 0)
        _ = try store.undo(#require(change.operationID))
        #expect(try store.exclusionRules(person: person).isEmpty)
        #expect(try count(index, person) == 2)
        _ = try store.excludeSimilar(person: person, seed: wrong, minimum: 0.95, expectedIndex: index.revision(), expectedPeople: store.revision(), accepts: { _ in true })
        try assign(store, person, wrong)
        #expect(try store.annotations(anchor: FacePersonSnapshot(wrong).anchor).first?.state == "assigned")
        #expect(try store.exclusionRules(person: person).count == 1)
    }
    @Test func previouslyRejectedFacesCanCreateARuleWithoutAnyNewAnnotationsAndUndoPreservesOldDecisions() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index), person = try store.save(name: "Человек").0.id
        let wrong = try add(index, "/Фото/Старый отказ.jpg", 0.8)
        _ = try store.label(person: person, action: "reject", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(wrong) }
        let before = try store.revision()
        let change = try store.excludeSimilar(person: person, seed: wrong, minimum: 0.95, expectedIndex: index.revision(), expectedPeople: before, accepts: { _ in true })
        #expect(change.changed == 0 && change.operationID != nil && change.revision == before + 1)
        let noop = try store.excludeSimilar(person: person, seed: wrong, minimum: 0.95, expectedIndex: index.revision(), expectedPeople: store.revision(), accepts: { _ in true })
        #expect(noop.operationID == nil)
        #expect(try store.undoOperationID() == change.operationID)
        _ = try store.undo(#require(change.operationID))
        #expect(try store.exclusionRules(person: person).isEmpty)
        #expect(try store.annotations(person: person).first?.state == "rejected")
    }
    @Test func ruleRemovalGuardsPersonRevisionAndScopeAndRollsBack() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), store = FacePeopleStore(index: index)
        let person = try store.save(name: "Человек").0.id, other = try store.save(name: "Другой").0.id
        let seed = try add(index, "/Фото/Лицо.jpg", 0.8)
        let change = try store.excludeSimilar(person: person, seed: seed, minimum: 0.95, expectedIndex: index.revision(), expectedPeople: store.revision(), accepts: { _ in true })
        let rule = try #require(store.exclusionRules(person: person).first)
        #expect(throws: (any Error).self) { try store.removeExclusionRule(rule.id, person: other, expectedPeople: store.revision()) }
        #expect(throws: (any Error).self) { try store.removeExclusionRule(rule.id, person: person, expectedPeople: store.revision() - 1) }
        var checks = 0
        #expect(throws: (any Error).self) {
            try store.removeExclusionRule(rule.id, person: person, expectedPeople: store.revision(), checkScope: { checks += 1; if checks == 2 { throw CancellationError() } })
        }
        #expect(try store.exclusionRules(person: person).count == 1 && store.undoOperationID() == change.operationID)
        #expect(!rule.matches(seed.face.embedding, model: "other-model"))
    }
}
