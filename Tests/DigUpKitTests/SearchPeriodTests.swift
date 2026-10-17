import Foundation
import Testing
@testable import DigUpKit

@Suite struct SearchPeriodTests {
    @Test func filtersWholeKeywordRankingBeforeBudgetsAndPages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-period-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        try store.db.transaction {
            for number in 0..<1105 {
                let id = try store.insert(Candidate(path: "/Фото Ё café/Снимок \(number).jpg", kind: .image,
                    size: 1, mtime: 1_640_995_200, inode: UInt64(number + 1), device: 1))
                let year = number < 1060 ? 2020 : 2000 + number % 4
                try store.db.run("UPDATE files SET info = ? WHERE id = ?", [.text("{\"taken\":\"\(year):02:03 12:00:00\"}"), .int(id)])
                try store.addSegment(file: id, kind: .name, modality: .text, text: "PERIOD742")
                if number == 1060 { for _ in 0..<1005 { try store.addSegment(file: id, kind: .ocr, modality: .text, text: "PERIOD742") } }
            }
        }
        let searcher = try Searcher(store: store, loadVectors: false)
        let period = try MediaDates.Period(from: 2000, through: 2003)
        let page = try searcher.snapshot("PERIOD742", queryVector: nil, period: period)
        #expect(page.total == 45)
        let hits = try page.page(offset: 0, limit: 40) + page.page(offset: 40, limit: 40)
        #expect(hits.count == 45 && Set(hits.map(\.path)).count == 45)
        #expect(hits.allSatisfy { period.accepts(MediaDates.date(captured: $0.info["taken"], modified: $0.modified)) })
        let preview = try searcher.search("PERIOD742", queryVector: nil, limit: 40, period: period)
        #expect(!preview.isEmpty && preview.allSatisfy { hit in hits.contains { $0.path == hit.path } })
        #expect(try searcher.snapshot("PERIOD742", queryVector: nil, period: MediaDates.Period(from: 1900, through: 1901)).total == 0)
        #expect(try searcher.snapshot("PERIOD742", queryVector: nil).total == 1105)
    }

    @Test func browseUsesCaptureDatesFallbackScopeAndRefreshWithoutInference() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-calendar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        for (number, path) in ["/chosen/Café.jpg", "/chosen/Cafe\u{301}.jpg", "/chosen/movie.mp4", "/hidden/old.jpg"].enumerated() {
            let id = try store.insert(Candidate(path: path, kind: number == 2 ? .video : .image,
                size: 1, mtime: 1_640_995_200, inode: UInt64(number + 1), device: 1))
            let taken = number == 0 ? "2000:01:01 00:00:00" : number == 1 ? "2003:12:31 23:59:59" : number == 3 ? "1800:01:01 00:00:00" : "invalid"
            try store.db.run("UPDATE files SET info = ? WHERE id = ?", [.text("{\"taken\":\"\(taken)\"}"), .int(id)])
            try store.addSegment(file: id, kind: .name, modality: .text, text: "CALENDAR742")
        }
        let searcher = try Searcher(store: store, loadVectors: false)
        let scope: (String) -> Bool = { $0.hasPrefix("/chosen/") }
        let bounds = try searcher.calendarYears(acceptsPath: scope)
        #expect(bounds.min == 2000 && bounds.max == 2022)
        let page = try searcher.snapshot("", queryVector: nil, kinds: [.image], period: MediaDates.Period(from: 2000, through: 2003), browse: true, acceptsPath: scope)
        #expect(page.total == 2)
        let hits = try page.page(offset: 0, limit: 40)
        #expect(hits.map { Data($0.path.utf8) } == [Data("/chosen/Cafe\u{301}.jpg".utf8), Data("/chosen/Café.jpg".utf8)])
        #expect(hits.allSatisfy { $0.keywordRank == nil && $0.cosine == nil })
        #expect(!searcher.vectorsLoaded)
        try store.db.run("UPDATE files SET info = '{\"taken\":\"1990:01:01 00:00:00\"}' WHERE path = ?", [.text("/chosen/Café.jpg")])
        // An old date-bound page cannot publish a file whose capture date has moved outside it.
        #expect(try page.page(offset: 0, limit: 40).count == 1)
        try searcher.reload()
        #expect(try searcher.calendarYears(acceptsPath: scope).min == 1990)
    }

    @Test func periodDoesNotRescaleSemanticRelevance() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-period-scale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder)
        for number in 0..<30 {
            let id = try store.insert(Candidate(path: "/chosen/\(number).jpg", kind: .image, size: 1, mtime: 1, inode: UInt64(number + 1), device: 1))
            try store.db.run("UPDATE files SET info = ? WHERE id = ?", [.text("{\"taken\":\"\(number < 15 ? 2000 : 2020):01:01 00:00:00\"}"), .int(id)])
            var vector = [Float](repeating: 0, count: Vectors.dimension); vector[0] = Float(number + 1) / 30; vector[1] = sqrt(1 - vector[0] * vector[0])
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
        }
        let searcher = try Searcher(store: store)
        var query = [Float](repeating: 0, count: Vectors.dimension); query[0] = 1
        let all = try searcher.snapshot("", queryVector: query, zGate: -100).page(offset: 0, limit: 40)
        let filtered = try searcher.snapshot("", queryVector: query, zGate: -100, period: MediaDates.Period(from: 2000, through: 2000)).page(offset: 0, limit: 40)
        #expect(filtered.count == 15)
        for hit in filtered { #expect(hit.z == all.first { $0.path == hit.path }?.z) }
    }
}
