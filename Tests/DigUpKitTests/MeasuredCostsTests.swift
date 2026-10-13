import Foundation
import Testing
@testable import DigUpKit
#if os(Windows)
import WinSDK
#endif

/// What indexing costs on this machine (`MeasuredCosts`), and the estimates made from it.
@Suite final class MeasuredCostsTests {
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func aKindsMeasuredCostCountsOnceThereIsEnoughOfIt() {
        var measured = MeasuredCosts()
        measured.add("image", units: 10, seconds: 3)
        #expect(measured.costs.image == Costs().image)   // 10 pictures aren't enough to go by
        measured.add("image", units: 10, seconds: 3)
        #expect(measured.costs.image == 0.3)
        #expect(measured.costs.docChunk == Costs().docChunk)
    }

    @Test func aSlowerMacScalesTheFixedCostsUntilItsOwnAreMeasured() {
        var measured = MeasuredCosts()
        measured.speed = MeasuredCosts.Speed(embedding: 3, ocr: 2)
        #expect(measured.costs.image == Costs().image * 3)
        #expect(measured.costs.screenshot == Costs().screenshot * 3)   // the slower of the two sets the pace
        measured.add("image", units: 40, seconds: 8)
        #expect(measured.costs.image == 0.2)                         // what it measured wins
        measured.speed = MeasuredCosts.Speed(embedding: 0.001, ocr: 1)
        #expect(measured.costs.docChunk == Costs().docChunk * 0.25)   // a check that's off by far is held in
    }

    @Test func recentWorkCountsMost() {
        var measured = MeasuredCosts()
        measured.add("image", units: 300, seconds: 300)   // 1 s a picture (a hot Mac, say)
        measured.add("image", units: 20, seconds: 2)      // then 0.1 s: past ten times enough, the past is halved
        #expect(measured.tallies["image"] == MeasuredCosts.Tally(seconds: 152, units: 170))
    }

    @Test func indexingKeepsWhatItCostsBesideTheIndex() throws {
        let notes = folder.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        for name in ["kyoto", "budget", "garden"] {
            try "Notes about \(name): what was planned, what happened, and what to do next time.".write(
                to: notes.appendingPathComponent("\(name).txt"), atomically: false, encoding: .utf8)
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        indexer.costsFolder = folder
        _ = try indexer.sync([notes])
        _ = try indexer.run()
        // Three notes of one chunk each; the first job started the model, which isn't what a chunk costs.
        #expect(MeasuredCosts.load(from: folder).tallies["docChunk"]?.units == 2)
        MeasuredCosts.setSpeed(MeasuredCosts.Speed(embedding: 1.5, ocr: 1), in: folder)
        let saved = MeasuredCosts.load(from: folder)
        #expect(saved.speed == MeasuredCosts.Speed(embedding: 1.5, ocr: 1))
        #expect(saved.tallies["docChunk"]?.units == 2)   // the speed joined what was there
    }

    @Test func repeatedAtomicUpdatesKeepTheLatestSpeedAndMeasurements() {
        var measured = MeasuredCosts()
        measured.add("docChunk", units: 20, seconds: 2)
        measured.save(to: folder)
        // These real atomic replacements exposed intermittent Windows sharing violations under the full suite.
        for i in 1...100 {
            let speed = MeasuredCosts.Speed(embedding: Double(i) / 10 + 1, ocr: 1)
            MeasuredCosts.setSpeed(speed, in: folder)
            let saved = MeasuredCosts.load(from: folder)
            #expect(saved.speed == speed)
            #expect(saved.tallies == measured.tallies)
        }
    }

    #if os(Windows)
    @Test func atomicUpdatesSurviveConcurrentMediaHelperLaunches() throws {
        let helper = try #require(FFmpeg.ffprobe)
        let workers = DispatchGroup()
        // Foundation's atomic staging handles used to escape into concurrently launched children. Exercise
        // real bundled helpers while replacing the same file, and verify every update, not just the last one.
        for _ in 0..<3 {
            workers.enter()
            DispatchQueue.global().async {
                defer { workers.leave() }
                do {
                    for _ in 0..<30 {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: helper)
                        process.arguments = ["-version"]
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        try process.run()
                        process.waitUntilExit()
                        #expect(process.terminationStatus == 0)
                    }
                } catch { Issue.record(error) }
            }
        }
        defer { workers.wait() }
        for i in 1...300 {
            var measured = MeasuredCosts()
            measured.speed = MeasuredCosts.Speed(embedding: Double(i), ocr: 1)
            measured.add("docChunk", units: Double(i), seconds: 2)
            measured.save(to: folder)
            #expect(MeasuredCosts.load(from: folder) == measured)
        }
    }

    @Test func failedAtomicReplacementKeepsThePreviousFileAndCleansItsTemporary() throws {
        var previous = MeasuredCosts()
        previous.speed = MeasuredCosts.Speed(embedding: 2, ocr: 1)
        previous.save(to: folder)
        let original = try Data(contentsOf: MeasuredCosts.file(in: folder))
        let handle = try #require(FileAccess.path(MeasuredCosts.file(in: folder).path).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        })
        try #require(handle != INVALID_HANDLE_VALUE)
        defer { CloseHandle(handle) }
        var changed = previous
        changed.speed = MeasuredCosts.Speed(embedding: 3, ocr: 1)
        changed.save(to: folder) // The held reader denies replacement for longer than all bounded retries.
        #expect(try Data(contentsOf: MeasuredCosts.file(in: folder)) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["costs.json"])
    }

    @Test func temporaryDeleteSharingDenialDoesNotDropTheUpdate() throws {
        var previous = MeasuredCosts()
        previous.speed = MeasuredCosts.Speed(embedding: 2, ocr: 1)
        previous.save(to: folder)
        let handle = try #require(FileAccess.path(MeasuredCosts.file(in: folder).path).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        })
        try #require(handle != INVALID_HANDLE_VALUE)
        let bits = UInt(bitPattern: handle), closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.04)
            CloseHandle(HANDLE(bitPattern: bits))
            closed.signal()
        }
        defer { closed.wait() }
        var changed = previous
        changed.speed = MeasuredCosts.Speed(embedding: 3, ocr: 1)
        changed.save(to: folder)
        #expect(MeasuredCosts.load(from: folder) == changed)
    }
    #endif
}
