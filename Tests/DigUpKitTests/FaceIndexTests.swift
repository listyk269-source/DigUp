import Foundation
import Testing
@testable import DigUpKit

@Suite struct FaceIndexTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-faces-\(UUID().uuidString)") }
    private func observation(_ loc: Double? = nil, first: Float = 1) -> FaceObservation {
        var vector = [Float](repeating: 0, count: 128)
        vector[0] = first; vector[1] = sqrt(1 - first * first)
        return FaceObservation(bbox: [0.1, 0.2, 0.3, 0.4], landmarks: [0.2, 0.3, 0.3, 0.3, 0.25, 0.4, 0.2, 0.5, 0.3, 0.5],
                               score: 0.98, embedding: vector, loc: loc)
    }
    @Test func atomicReindexKeepsUnicodePathsDistinctAndDoesNotDuplicate() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FaceIndexStore(directory: directory)
        let a = FaceFileVersion(path: "/Тестовые фото/Café 🦊.jpg", kind: "image", size: 10, modified: 20)
        let b = FaceFileVersion(path: "/Тестовые фото/Cafe\u{301} 🦊.mp4", kind: "video", size: 30, modified: 40)
        try store.replace(a, model: "sface", config: "v1", frames: 1, faces: [observation()])
        try store.replace(b, model: "sface", config: "v1", frames: 2, faces: [observation(0), observation(2)])
        #expect(try store.observations().count == 3)
        let oldID = try #require(store.observations(path: a.path).first?.face.id)
        try store.replace(a, model: "sface", config: "v1", frames: 1, faces: [observation()])
        #expect(try store.observations().count == 3)
        #expect(try store.observations(path: a.path).first?.face.id != oldID)
        #expect(try store.observations(path: b.path).map(\.face.loc) == [0, 2])
        #expect(try store.completed(a, model: "sface", config: "v1"))
        #expect(try !store.completed(a, model: "new-model", config: "v1"))
        #expect(try !store.completed(a, model: "sface", config: "new-sampling"))
        #expect(try !store.completed(FaceFileVersion(path: a.path, kind: "video", size: 10, modified: 20), model: "sface", config: "v1"))
        #expect(try !store.completed(FaceFileVersion(path: a.path, kind: "image", size: 11, modified: 20), model: "sface", config: "v1"))
    }
    @Test func invalidObservationCannotReplaceGoodIndexAndFailureCanRetry() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FaceIndexStore(directory: directory)
        let file = FaceFileVersion(path: "/test.jpg", kind: "image", size: 1, modified: 2)
        try store.replace(file, model: "sface", config: "v1", frames: 1, faces: [observation()])
        let invalid = FaceObservation(bbox: [0, 0, 2, 1], landmarks: [], score: .nan, embedding: [], loc: -1)
        #expect(throws: (any Error).self) { try store.replace(file, model: "sface", config: "v1", frames: 1, faces: [invalid]) }
        #expect(try store.observations().count == 1)
        try store.replace(file, model: "sface", config: "v1", frames: 0, faces: [], failed: true)
        #expect(try !store.completed(file, model: "sface", config: "v1"))
        #expect(try store.observations().isEmpty)
        try store.replace(file, model: "sface", config: "v1", frames: 1, faces: [])
        #expect(try store.completed(file, model: "sface", config: "v1")) // No face is a successful observation too.
    }
    @Test func deletingSemanticRecordRemovesFacesButUnavailableDiskDoesNot() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FaceIndexStore(directory: directory)
        let retained = FaceFileVersion(path: "/unplugged/Фото.jpg", kind: "image", size: 1, modified: 2)
        let deleted = FaceFileVersion(path: "/deleted.jpg", kind: "image", size: 1, modified: 2)
        for file in [retained, deleted] { try store.replace(file, model: "sface", config: "v1", frames: 1, faces: [observation()]) }
        try store.removeDeleted(retainedPaths: [Data(retained.path.utf8)])
        #expect(try store.observations().map(\.file.path) == [retained.path])
    }
    @Test func normalizedVectorsHaveIndependentFaceCosines() {
        #expect(FaceIndexStore.cosine(observation().embedding, observation(first: 0.8).embedding).map { abs($0 - 0.8) < 0.0001 } == true)
        #expect(FaceIndexStore.cosine([], []).isNil)
        var corrupt = observation().embedding; corrupt[0] = .nan
        #expect(FaceIndexStore.cosine(corrupt, observation().embedding).isNil)
    }
    @Test func savedObservationLookupUsesExactVersionFrameAndBoxAfterNumericIDReplacement() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory)
        let file = FaceFileVersion(path: "/Фото/Café 🦊.mp4", kind: "video", size: 10, modified: 20)
        try index.replace(file, model: "sface", config: "v1", frames: 2, faces: [observation(0), observation(2)])
        let face = try #require(index.observations(path: file.path).last), snapshot = FacePersonSnapshot(face)
        #expect(try index.observationID(matching: snapshot) == face.face.id)
        try index.replace(file, model: "sface", config: "v1", frames: 2, faces: [observation(0), observation(2)])
        #expect(try index.observationID(matching: snapshot) != face.face.id)
        #expect(try index.observationID(matching: snapshot) == index.observations(path: file.path).last?.face.id)
        try index.replace(file, model: "new-model", config: "v1", frames: 2, faces: [observation(0), observation(2)])
        #expect(try index.observationID(matching: snapshot) == nil)
        try index.replace(FaceFileVersion(path: file.path, kind: "video", size: 11, modified: 20), model: "sface", config: "v1", frames: 2, faces: [observation(0), observation(2)])
        #expect(try index.observationID(matching: snapshot) == nil)
    }
    @Test func stagedVideoPublicationRollsBackTruncationAndHonorsCancellation() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FaceIndexStore(directory: directory)
        let file = FaceFileVersion(path: "/Фото/video.mp4", kind: "video", size: 5, modified: 6)
        try store.replace(file, model: "sface", config: "v1", frames: 1, faces: [observation(0)])
        let original = try #require(store.observations().first?.face.id)
        let staged = directory.appendingPathComponent("staged.jsonl")
        var valid = try JSONEncoder().encode(observation(2)); valid.append(10)
        var broken = valid; broken.append(contentsOf: Data("{truncated".utf8))
        try broken.write(to: staged)
        #expect(throws: (any Error).self) {
            try store.replaceStaged(file, model: "sface", config: "v2", frames: 2, staged: staged, cancellation: FaceCancellation())
        }
        #expect(try store.observations().first?.face.id == original)
        try valid.write(to: staged)
        let cancelled = FaceCancellation(); cancelled.cancel()
        #expect(throws: CancellationError.self) {
            try store.replaceStaged(file, model: "sface", config: "v2", frames: 2, staged: staged, cancellation: cancelled)
        }
        #expect(try store.observations().first?.face.id == original)
        try store.replaceStaged(file, model: "sface", config: "v2", frames: 2, staged: staged, cancellation: FaceCancellation())
        #expect(try store.observations().map(\.face.loc) == [2])
        #expect(try store.completed(file, model: "sface", config: "v2"))
    }
    @Test func cancellationIsStickyAndStopsBeforeLaunchingAnything() {
        let cancellation = FaceCancellation()
        cancellation.cancel()
        #expect(cancellation.isCancelled)
        #expect(throws: CancellationError.self) { try cancellation.check() }
        let process = Process()
        #expect(throws: CancellationError.self) { try cancellation.launch(process) }
        #expect(!process.isRunning)
    }
}

private extension Optional {
    var isNil: Bool { self == nil }
}
