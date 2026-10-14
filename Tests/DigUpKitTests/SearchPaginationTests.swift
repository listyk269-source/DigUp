import Foundation
import Testing
@testable import DigUpKit

@Suite struct SearchPaginationTests {
    @Test func pagesReachEveryEligibleFileBeyondBothKeywordBudgets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        try store.db.transaction {
            for index in 0..<1105 {
                let id = try store.insert(Candidate(path: "/Фото café 🦊/match-\(index).txt", kind: .doc,
                    size: 1, mtime: 1, inode: UInt64(index + 1), device: 1))
                try store.addSegment(file: id, kind: .chunk, modality: .text, text: "PAGINATION742")
                if index == 0 { // one long file must never occupy multiple result positions
                    for _ in 0..<1005 { try store.addSegment(file: id, kind: .chunk, modality: .text, text: "PAGINATION742") }
                }
            }
        }
        let searcher = try Searcher(store: store, loadVectors: false)
        let snapshot = try searcher.snapshot("PAGINATION742", queryVector: nil)
        #expect(snapshot.total == 1105)
        var paths: [String] = []
        for offset in stride(from: 0, to: snapshot.total, by: 40) {
            paths += try snapshot.page(offset: offset, limit: 40).map(\.path)
        }
        #expect(paths.count == 1105)
        #expect(Set(paths).count == 1105)
        #expect(try snapshot.page(offset: 40, limit: 40).map(\.path) == Array(paths[40..<80]))
        #expect(try snapshot.page(offset: Int.max, limit: Int.max).isEmpty)
        #expect(try snapshot.page(offset: -1, limit: -1).isEmpty)
        #expect(try searcher.snapshot("PAGINATION742", queryVector: nil, acceptsPath: { _ in false }).total == 0)
    }

    @Test func rankingSurvivesReloadAndSkipsDeletedFilesWithoutReordering() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        var ids: [Int64] = []
        for index in 0..<85 {
            let id = try store.insert(Candidate(path: "/selected/photo-\(index).jpg", kind: .image,
                size: 1, mtime: 1, inode: UInt64(index + 1), device: 1))
            ids.append(id)
            var vector = [Float](repeating: 0, count: Vectors.dimension)
            vector[0] = 1
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
        }
        let searcher = try Searcher(store: store)
        var query = [Float](repeating: 0, count: Vectors.dimension)
        query[0] = 1
        let snapshot = try searcher.snapshot("", queryVector: query, zGate: -100)
        let expected = try snapshot.page(offset: 40, limit: 40).map(\.path)
        try store.db.run("DELETE FROM files WHERE id = ?", [.int(ids[40])])
        try searcher.reload()
        #expect(snapshot.total == 85)
        #expect(try snapshot.page(offset: 40, limit: 40).map(\.path) == Array(expected.dropFirst()))
        #expect(try searcher.snapshot("", queryVector: query, zGate: -100).total == 84)
    }

    @Test func overviewCountsOnlySelectedMetadataAndKeepsRecentOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-overview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        for (index, path) in ["/chosen/one.txt", "/chosen/two.md", "/chosen/raw.CR2", "/old/hidden.txt"].enumerated() {
            let id = try store.insert(Candidate(path: path, kind: index == 2 ? .image : .doc,
                size: 1, mtime: 1, inode: UInt64(index + 1), device: 1))
            try store.db.run("UPDATE files SET state = ?, indexed_at = ?, detail = ? WHERE id = ?",
                [.text(index == 2 ? "failed" : "done"), .double(Double(index + 1)),
                 .text(index == 2 ? UnsupportedRawImage.failureNotes[0] : ""), .int(id)])
            try store.addSegment(file: id, kind: .chunk, modality: .text, text: "Private body is not returned by overview.")
        }
        let result = try store.overview { $0.hasPrefix("/chosen/") }
        #expect(result.byKindAndState["doc"]?["done"] == 2)
        #expect(result.unsupportedRaw == 1)
        #expect(result.segments == 3)
        #expect(result.vectors == 0)
        #expect(result.recent.map(\.path) == ["/chosen/two.md", "/chosen/one.txt"])
        #expect(result.lastIndexed == 2)
        #expect(try store.overview { _ in false }.recent.isEmpty)
    }
}
