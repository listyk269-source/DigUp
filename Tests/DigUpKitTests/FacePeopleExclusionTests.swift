import Foundation
import Testing
@testable import DigUpKit

@Suite struct FacePeopleExclusionTests {
    private func face(_ axis: Int, loc: Double? = nil) -> FaceObservation {
        var vector = [Float](repeating: 0, count: 128); vector[axis] = 1
        return FaceObservation(bbox: [0.1 + Double(axis) * 0.1, 0.2, 0.2, 0.3],
            landmarks: [0.2, 0.3, 0.3, 0.3, 0.25, 0.4, 0.2, 0.5, 0.3, 0.5], score: 0.98, embedding: vector, loc: loc)
    }
    private func add(_ index: FaceIndexStore, _ path: String, _ faces: [FaceObservation]) throws -> [IndexedFace] {
        let file = FaceFileVersion(path: path, kind: path.hasSuffix("mp4") ? "video" : "image", size: 100, modified: 1)
        try index.replace(file, model: FaceModels.modelID, config: "unit", frames: faces.count, faces: faces)
        return try index.observations(path: path)
    }
    private func assign(_ people: FacePeopleStore, _ person: String, _ faces: [IndexedFace]) throws {
        _ = try people.label(person: person, action: "assign", expectedIndex: people.index.revision(), accepts: { _ in true }) { consume in
            for face in faces { try consume(face) }
        }
    }
    private func summary(_ index: FaceIndexStore) throws -> FaceSuggestionSummary {
        try FaceSuggestionSummary.calculate(index: index,
            key: FaceSuggestionSummaryKey(scopeRevision: 1, indexRevision: index.revision(), peopleRevision: FacePeopleStore(index: index).revision(), minimumCosine: 0.9),
            cancellation: FaceCancellation(), acceptsCurrent: { _ in true }, acceptsScope: { _ in true }, checkScope: {})
    }
    @Test func exclusionRemovesContaminatedReferencesPreservesOthersAndUndoRestoresProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-exclude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let a = try people.save(name: "Люди А").0, b = try people.save(name: "Люди Б").0
        let seed = try add(index, "/Фото/Верный.jpg", [face(0)])
        let wrong = try add(index, "/Фото/Ошибка Ё café.jpg", [face(1), face(0), face(2)])
        _ = try add(index, "/Фото/Ложное предложение.jpg", [face(1)])
        _ = try add(index, "/Фото/Верное предложение.jpg", [face(0)])
        try assign(people, a.id, seed + Array(wrong.prefix(2))); try assign(people, b.id, [wrong[2]])
        let observations = try index.observations(), revision = try index.revision(), bAnnotations = try people.annotations(person: b.id)
        let before = try #require(summary(index).people.first { $0.personID == a.id })
        #expect(before.pendingCount == 2 && before.referenceCount == 2 && before.referenceSourceCount == 3)
        let change = try people.excludeFile(person: a.id, file: wrong[0].file, expectedIndex: revision,
            expectedPeople: people.revision(), accepts: { _ in true })
        let after = try #require(summary(index).people.first { $0.personID == a.id })
        #expect(change.changed == 3 && after.pendingCount == 1 && after.referenceCount == 1 && after.referenceSourceCount == 1)
        #expect(try people.annotations(person: a.id).filter { $0.state == "rejected" }.count == 3)
        #expect(try people.annotations(person: b.id).map(\.anchor) == bAnnotations.map(\.anchor))
        #expect(try people.annotations(person: b.id).allSatisfy { $0.state == "assigned" })
        #expect(try index.revision() == revision)
        #expect(try index.observations().map { $0.face.embedding } == observations.map { $0.face.embedding })
        _ = try people.undo(#require(change.operationID), expectedPeople: people.revision())
        let restored = try #require(summary(index).people.first { $0.personID == a.id })
        #expect(restored.pendingCount == before.pendingCount && restored.referenceCount == before.referenceCount)
        #expect(restored.referenceSourceCount == before.referenceSourceCount)
    }
    @Test func wholeVideoExclusionIncludesUnloadedFramesAndKeepsDistinctUnicodePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-exclude-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let person = try people.save(name: "Человек").0
        let video = try add(index, "/Фото/Café Ё.mp4", (0..<85).map { face(0, loc: Double($0)) })
        let distinct = try add(index, "/Фото/Cafe\u{301} Ё.mp4", [face(0, loc: 1)])
        try assign(people, person.id, video + distinct)
        let change = try people.excludeFile(person: person.id, file: video[0].file, expectedIndex: index.revision(),
            expectedPeople: people.revision(), accepts: { _ in true })
        let annotations = try people.annotations(person: person.id)
        #expect(change.changed == 85 && annotations.filter { $0.state == "rejected" }.count == 85)
        #expect(annotations.filter { $0.state == "assigned" }.map { Data($0.snapshot.file.path.utf8) } == [Data(distinct[0].file.path.utf8)])
        _ = try people.undo(#require(change.operationID))
        #expect(try people.annotations(person: person.id).allSatisfy { $0.state == "assigned" })
    }
    @Test func staleRevisionsAndScopeChangesCannotPartiallyExcludeAFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-exclude-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let person = try people.save(name: "Человек").0, faces = try add(index, "/Фото/Проверка.jpg", [face(0), face(1)])
        try assign(people, person.id, faces)
        let revision = try people.revision(), undo = try people.undoOperationID()
        #expect(throws: (any Error).self) { try people.excludeFile(person: person.id, file: faces[0].file, expectedIndex: index.revision() - 1, accepts: { _ in true }) }
        #expect(throws: (any Error).self) { try people.excludeFile(person: person.id, file: faces[0].file, expectedIndex: index.revision(), expectedPeople: revision - 1, accepts: { _ in true }) }
        #expect(throws: (any Error).self) { try people.excludeFile(person: person.id, file: faces[0].file, expectedIndex: index.revision(), accepts: { _ in false }) }
        var checks = 0
        #expect(throws: (any Error).self) {
            try people.excludeFile(person: person.id, file: faces[0].file, expectedIndex: index.revision(), accepts: { _ in true }, checkScope: {
                checks += 1; if checks == 2 { throw CancellationError() }
            })
        }
        #expect(try people.revision() == revision && people.undoOperationID() == undo)
        #expect(try people.annotations(person: person.id).allSatisfy { $0.state == "assigned" })
    }
}
