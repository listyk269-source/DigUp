import Foundation
import Testing
@testable import DigUpKit

@Suite struct SearchScopeTests {
    @Test func selectedWordsSurviveMoreThanAThousandUnselectedMatches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        try store.db.transaction {
            for index in 0..<1001 {
                let id = try store.insert(Candidate(path: "/old/11112222-\(index).txt", kind: .doc,
                                                     size: 1, mtime: 1, inode: UInt64(index + 1), device: 1))
                try store.addSegment(file: id, kind: .chunk, modality: .text, text: "11112222 grok")
            }
        }
        let selected = "/chosen/it's selected.txt"
        let id = try store.insert(Candidate(path: selected, kind: .doc, size: 1, mtime: 1, inode: 2000, device: 1))
        try store.addSegment(file: id, kind: .chunk, modality: .text, text: "11112222 Grok4")
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("11112222", queryVector: nil, limit: 1).first?.path.hasPrefix("/old/") == true)
        #expect(try searcher.search("11112222", queryVector: nil, limit: 1,
                                   acceptsPath: { $0.hasPrefix("/chosen/") }).map(\.path) == [selected])
        // Exact occurrences outside the selection must not disable prefix rescue inside it.
        #expect(try searcher.search("grok", queryVector: nil, limit: 1,
                                   acceptsPath: { $0.hasPrefix("/chosen/") }).map(\.path) == [selected])
        #expect(try searcher.search("11112222", queryVector: nil, acceptsPath: { _ in false }).isEmpty)
    }

    @Test func selectedSemanticCandidateIsRankedBeforeTheResultLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-scope-vector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        // Fixed unit vectors isolate ranking from the model. Release smoke uses actual EmbeddingGemma vectors.
        for (index, cosine) in [Float(0.95), 0.8, -0.5].enumerated() {
            let path = index == 1 ? "/chosen/scene.jpg" : "/old/scene-\(index).jpg"
            let id = try store.insert(Candidate(path: path, kind: .image, size: 1, mtime: 1,
                                                 inode: UInt64(index + 1), device: 1))
            var vector = [Float](repeating: 0, count: Vectors.dimension)
            vector[0] = cosine
            vector[1] = (1 - cosine * cosine).squareRoot()
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
        }
        var query = [Float](repeating: 0, count: Vectors.dimension)
        query[0] = 1
        let searcher = try Searcher(store: store)
        #expect(try searcher.search("", queryVector: query, limit: 1, zGate: -100).first?.path == "/old/scene-0.jpg")
        let selected = try searcher.search("", queryVector: query, limit: 1, zGate: -100,
                                           acceptsPath: { $0.hasPrefix("/chosen/") })
        #expect(selected.map(\.path) == ["/chosen/scene.jpg"])
        #expect(abs((selected.first?.cosine ?? 0) - 0.8) < 0.001)
    }

    @Test func unselectedVectorsDoNotSetTheSelectionsSemanticBaseline() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-scope-scale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        for index in 0..<106 {
            let chosen = index < 6
            let cosine: Float = index == 0 ? 0.9 : chosen ? 0.1 : 0.95
            let path = (chosen ? "/chosen/" : "/old/") + "scene-\(index).jpg"
            let id = try store.insert(Candidate(path: path, kind: .image, size: 1, mtime: 1,
                                                 inode: UInt64(index + 1), device: 1))
            var vector = [Float](repeating: 0, count: Vectors.dimension)
            vector[0] = cosine
            vector[1] = (1 - cosine * cosine).squareRoot()
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
        }
        var query = [Float](repeating: 0, count: Vectors.dimension)
        query[0] = 1
        let searcher = try Searcher(store: store)
        #expect(try searcher.search("", queryVector: query).isEmpty)
        #expect(try searcher.search("", queryVector: query,
                                   acceptsPath: { $0.hasPrefix("/chosen/") }).map(\.path) == ["/chosen/scene-0.jpg"])
    }
}
