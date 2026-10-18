import Foundation
import Testing
@testable import DigUpKit

@Suite struct FacePeopleSimilarExclusionTests {
    private func face(_ angle: Double, loc: Double? = nil) -> FaceObservation {
        var vector = [Float](repeating: 0, count: 128)
        vector[0] = Float(cos(angle)); vector[1] = Float(sin(angle))
        return FaceObservation(bbox: [0.1 + angle * 0.05, 0.2, 0.2, 0.3], landmarks: [0.2, 0.3, 0.3, 0.3, 0.25, 0.4, 0.2, 0.5, 0.3, 0.5], score: 0.98, embedding: vector, loc: loc)
    }
    private func add(_ index: FaceIndexStore, _ path: String, _ faces: [FaceObservation]) throws -> [IndexedFace] {
        try index.replace(FaceFileVersion(path: path, kind: path.hasSuffix("mp4") ? "video" : "image", size: 100, modified: 1),
            model: FaceModels.modelID, config: "unit", frames: faces.count, faces: faces)
        return try index.observations(path: path)
    }
    @Test func exclusionCoversUnloadedFilesButPreservesOtherFacesAndOtherPeopleWithAtomicUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try FaceIndexStore(directory: folder), store = FacePeopleStore(index: index)
        let person = try store.save(name: "Альбом").0, other = try store.save(name: "Другой").0
        let source = try add(index, "/Фото/Группа Ё.jpg", [face(0), face(2)])
        var matches = [source[0]]
        for number in 0..<85 { matches += try add(index, "/Фото/Совпадение \(number).jpg", [face(0.1)]) }
        matches += try add(index, "/Фото/Видео café.mp4", (0..<85).map { face(0.1, loc: Double($0)) })
        _ = try add(index, "/Фото/Не транзитивное.jpg", [face(0.9)])
        _ = try store.label(person: person.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) { consume in
            // Both the correct face in the group and the incorrect identity are explicitly assigned.
            for face in source + Array(matches.dropFirst().prefix(45)) { try consume(face) }
        }
        _ = try store.label(person: other.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) { consume in try consume(matches.last!) }
        let revision = try index.revision(), before = try store.annotations(), descriptors = try index.observations().map { $0.face.embedding }
        let change = try store.excludeSimilar(person: person.id, seed: source[0], minimum: 0.95,
            expectedIndex: revision, expectedPeople: store.revision(), accepts: { _ in true })
        let own = try store.annotations(person: person.id)
        #expect(change.changed == matches.count && matches.count > 80)
        #expect(own.filter { $0.state == "rejected" }.count == matches.count)
        #expect(own.filter { $0.state == "assigned" }.map(\.anchor) == [FacePersonSnapshot(source[1]).anchor])
        #expect(try store.annotations(person: other.id).allSatisfy { $0.state == "assigned" })
        #expect(try index.revision() == revision && index.observations().map { $0.face.embedding } == descriptors)
        let noop = try store.excludeSimilar(person: person.id, seed: source[0], minimum: 0.95,
            expectedIndex: revision, expectedPeople: store.revision(), accepts: { _ in true })
        #expect(noop.changed == 0)
        #expect(try store.undoOperationID() == change.operationID)
        _ = try store.undo(#require(change.operationID))
        #expect(try store.annotations().map { "\($0.anchor):\($0.personID):\($0.state)" } == before.map { "\($0.anchor):\($0.personID):\($0.state)" })
    }
    @Test func directMatchesRespectThresholdAndScopeWithoutTransitiveExpansion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try FaceIndexStore(directory: folder), store = FacePeopleStore(index: index)
        let seed = try add(index, "/Фото/Начало.jpg", [face(0)])[0]
        let near = try add(index, "/Фото/Café.jpg", [face(0.4)])[0]
        let transitive = try add(index, "/Фото/Cafe\u{301}.jpg", [face(0.8)])[0]
        let outside = try add(index, "/Недоступно/Совпадает.jpg", [face(0)])[0]
        var ids: [Int64] = []
        try store.forEachSimilar(to: seed, minimum: 0.9, accepts: { !$0.path.hasPrefix("/Недоступно") }) { face, _ in ids.append(face.face.id) }
        #expect(ids == [seed.face.id, near.face.id])
        #expect(!ids.contains(transitive.face.id) && !ids.contains(outside.face.id))
        #expect((FaceIndexStore.cosine(near.face.embedding, transitive.face.embedding) ?? 0) > 0.9)
    }
    @Test func staleInputsAndCancellationRollbackTheWholeGroupAndPreserveUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try FaceIndexStore(directory: folder), store = FacePeopleStore(index: index)
        let person = try store.save(name: "Человек").0, seed = try add(index, "/Фото/Начало.jpg", [face(0)])[0]
        _ = try add(index, "/Фото/Другое.jpg", [face(0)])
        let revision = try store.revision(), undo = try store.undoOperationID()
        for minimum in [Double.nan, .infinity, 1.1] {
            #expect(throws: (any Error).self) { try store.excludeSimilar(person: person.id, seed: seed, minimum: minimum, expectedIndex: index.revision(), expectedPeople: revision, accepts: { _ in true }) }
        }
        #expect(throws: (any Error).self) { try store.excludeSimilar(person: person.id, seed: seed, minimum: 0.5, expectedIndex: index.revision() - 1, expectedPeople: revision, accepts: { _ in true }) }
        #expect(throws: (any Error).self) { try store.excludeSimilar(person: person.id, seed: seed, minimum: 0.5, expectedIndex: index.revision(), expectedPeople: revision - 1, accepts: { _ in true }) }
        var checks = 0
        #expect(throws: (any Error).self) {
            try store.excludeSimilar(person: person.id, seed: seed, minimum: 0.5, expectedIndex: index.revision(), expectedPeople: revision, accepts: { _ in true }, checkScope: {
                checks += 1; if checks == 4 { throw CancellationError() }
            })
        }
        #expect(try store.annotations().isEmpty && store.revision() == revision && store.undoOperationID() == undo)
    }
}
