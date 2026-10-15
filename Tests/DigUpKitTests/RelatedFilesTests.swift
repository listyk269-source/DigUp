import Foundation
import Testing
@testable import DigUpKit

@Suite struct RelatedFilesTests {
    private func vector(_ x: Float, _ y: Float? = nil) -> [Float] {
        var result = [Float](repeating: 0, count: Vectors.dimension)
        result[0] = x; result[1] = y ?? (1 - x * x).squareRoot()
        return result
    }
    private func add(_ store: IndexStore, _ path: String, _ values: [[Float]], kind: FileKind = .doc) throws -> Int64 {
        var inode: Int64 = 1
        try store.db.query("SELECT coalesce(MAX(id), 0) + 1 FROM files") { inode = $0.int(0) }
        let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: UInt64(inode), device: 1))
        for (index, value) in values.enumerated() {
            try store.addSegment(file: id, kind: .chunk, modality: .text, loc: Double(index + 1), vector: value)
        }
        return id
    }
    @Test func closestFragmentOncePerFileAndBoundedPages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-related-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        _ = try add(store, "/Фото café/seed.txt", [vector(1)])
        _ = try add(store, "/Фото café/near.txt", [vector(0.5), vector(0.95)])
        _ = try add(store, "/Фото café/second.txt", [vector(0.8)])
        _ = try add(store, "/Фото café/weak.txt", [vector(0.2)])
        let searcher = try Searcher(store: store, loadVectors: false)
        let first = try searcher.relatedFiles(to: "/Фото café/seed.txt", limit: 1)
        #expect(first.total == 2 && first.basis == "file_mean")
        #expect(first.hits.map(\.path) == ["/Фото café/near.txt"])
        #expect(first.hits.first?.loc == 2)
        #expect(abs((first.hits.first?.cosine ?? 0) - 0.95) < 0.001)
        #expect(try searcher.relatedFiles(to: "/Фото café/seed.txt", offset: 1, limit: 1).hits.map(\.path) == ["/Фото café/second.txt"])
        #expect(try searcher.relatedFiles(to: "/Фото café/seed.txt", offset: Int.max, limit: Int.max).hits.isEmpty)
    }
    @Test func filtersApplyBeforeNeighborLimitAndSeedMustBeInScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-related-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        _ = try add(store, "/selected/seed.txt", [vector(1)])
        for index in 0..<50 { _ = try add(store, "/excluded/\(index).txt", [vector(0.99)]) }
        _ = try add(store, "/selected/picture.jpg", [vector(0.95)], kind: .image)
        _ = try add(store, "/selected/allowed.txt", [vector(0.8)])
        let searcher = try Searcher(store: store)
        let page = try searcher.relatedFiles(to: "/selected/seed.txt", limit: 1, kinds: [.doc], acceptsPath: { $0.hasPrefix("/selected/") })
        #expect(page.total == 1 && page.hits.first?.path == "/selected/allowed.txt")
        #expect(try searcher.relatedFiles(to: "/selected/seed.txt", acceptsPath: { _ in false }).seed == nil)
    }
    @Test func meanAndMatchedFragmentHaveDifferentHonestBases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-related-mean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        let seed = try add(store, "/seed.txt", [vector(1, 0), vector(0, 1)])
        var segment: Int64 = 0
        try store.db.query("SELECT id FROM segments WHERE file = ? AND loc = 1", [.int(seed)]) { segment = $0.int(0) }
        _ = try add(store, "/mean.txt", [vector(0.70710677, 0.70710677)])
        _ = try add(store, "/fragment.txt", [vector(0.95)])
        let searcher = try Searcher(store: store)
        #expect(try searcher.relatedFiles(to: "/seed.txt").hits.first?.path == "/mean.txt")
        let fragment = try searcher.relatedFiles(to: "/seed.txt", segmentID: segment)
        #expect(fragment.basis == "matched_fragment" && fragment.hits.first?.path == "/fragment.txt")
    }
    @Test func unicodeByteIdentityAndForeignSegmentIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-related-unicode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        _ = try add(store, "/Фото/Café 🦊.txt", [vector(1)])
        let other = try add(store, "/Фото/Cafe\u{301} 🦊.txt", [vector(0.95)])
        var foreign: Int64 = 0
        try store.db.query("SELECT id FROM segments WHERE file = ? AND vec IS NOT NULL", [.int(other)]) { foreign = $0.int(0) }
        let searcher = try Searcher(store: store)
        let page = try searcher.relatedFiles(to: "/Фото/Café 🦊.txt")
        #expect(page.seed?.path.utf8.elementsEqual("/Фото/Café 🦊.txt".utf8) == true)
        #expect(page.hits.first?.path.utf8.elementsEqual("/Фото/Cafe\u{301} 🦊.txt".utf8) == true)
        #expect(try searcher.relatedFiles(to: "/Фото/Café 🦊.txt", segmentID: foreign).seed == nil)
    }
    @Test func emptyCorruptAndChangedFilesDoNotProduceFalseNodes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-related-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        let seed = try add(store, "/seed.txt", [vector(1)])
        _ = try add(store, "/nan.txt", [vector(.nan, 0)])
        _ = try add(store, "/empty.txt", [])
        let searcher = try Searcher(store: store)
        #expect(try searcher.relatedFiles(to: "/seed.txt").hits.isEmpty)
        #expect(try searcher.relatedFiles(to: "/empty.txt").seed == nil)
        try store.delete(seed)
        _ = try add(store, "/replacement.txt", [vector(1)])
        #expect(try searcher.relatedFiles(to: "/seed.txt").seed == nil)
    }
    @Test func channelEvidenceIsComputedIndependentlyAndNeverInventsFacesOrOCR() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-modal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        let seed = try add(store, "/seed.mp4", [], kind: .video)
        try store.addSegment(file: seed, kind: .frame, modality: .image, loc: 3, vector: vector(1, 0))
        try store.addSegment(file: seed, kind: .audio, modality: .audio, loc: 10, vector: vector(0, 1))
        let image = try add(store, "/picture.jpg", [], kind: .image)
        try store.addSegment(file: image, kind: .image, modality: .image, vector: vector(0.95))
        let sound = try add(store, "/sound.wav", [], kind: .audio)
        try store.addSegment(file: sound, kind: .audio, modality: .audio, loc: 25, vector: vector(0, 1))
        let searcher = try Searcher(store: store)
        let visual = try searcher.relatedFiles(to: "/seed.mp4", minimumCosine: 0.9, matchTypes: [.visual])
        #expect(visual.hits.map(\.path) == ["/picture.jpg"])
        #expect(abs((visual.hits.first?.matchEvidence.first?.cosine ?? 0) - 0.95) < 0.001)
        #expect(visual.hits.first?.matchEvidence.first?.seedLoc == 3)
        let audio = try searcher.relatedFiles(to: "/seed.mp4", matchTypes: [.audio])
        #expect(audio.hits.map(\.path) == ["/sound.wav"])
        #expect(audio.hits.first?.matchEvidence.first?.loc == 25)
        #expect(try searcher.relatedFiles(to: "/seed.mp4", matchTypes: [.face]).total == 0)
        #expect(try searcher.relatedFiles(to: "/seed.mp4", matchTypes: [.ocr]).total == 0)
        let count = try searcher.relatedFiles(to: "/seed.mp4", limit: 0, visiblePaths: ["/sound.wav"])
        #expect(count.total == 2 && count.unexpandedCount == 1)
    }
    @Test func metadataEvidenceRequiresAnActualMatchingEXIFDate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        let seed = try add(store, "/seed.jpg", [vector(1)], kind: .image)
        let target = try add(store, "/match.jpg", [vector(0.95)], kind: .image)
        _ = try add(store, "/not-exif.jpg", [vector(0.99)], kind: .image)
        for id in [seed, target] { try store.finish(id, state: "ready", info: ["taken": "2026:10:15 10:11:12"]) }
        let searcher = try Searcher(store: store)
        let result = try searcher.relatedFiles(to: "/seed.jpg", matchTypes: [.metadata])
        #expect(result.hits.map(\.path) == ["/match.jpg"])
        #expect(result.hits.first?.matchEvidence.last?.value == "2026:10:15 10:11:12")
        #expect(result.hits.first?.matchEvidence.last?.cosine == nil)
    }
}
