import Foundation
import Testing
@testable import DigUpKit

@Suite struct FaceAutomaticTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-face-auto-\(UUID().uuidString)")
    }
    private func file(_ path: String = "/photos/one.jpg", size: Int64 = 10, modified: Double = 20) -> FaceFileVersion {
        FaceFileVersion(path: path, kind: "image", size: size, modified: modified)
    }
    private func job(_ file: FaceFileVersion, config: String = "v1", state: String = "done") -> FaceAutoJob {
        FaceAutoJob(file: file, model: "sface", config: config, state: state)
    }
    private func plan(_ files: [FaceFileVersion], _ jobs: [FaceAutoJob], settings: FaceAutoSettings = .init(),
                      config: String = "v1", retry: Bool = false) -> FaceAutoPlan {
        FaceAutoPlan.make(files: files, jobs: jobs, settings: settings, model: "sface", config: config,
                          retryFailures: retry, accepts: { _ in true })
    }

    @Test func legacyOptInRequiresCompletedJobsAndSavedPauseWinsOnRestart() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try FaceAutoSettings.load(from: folder, completedJobs: false)
        #expect(!first.enabled && !first.paused)
        var migrated = try FaceAutoSettings.load(from: folder, completedJobs: true, previousStep: 3)
        #expect(migrated.enabled && migrated.sampleSeconds == 3)
        migrated.setEnabled(false)
        try migrated.save(to: folder)
        let restarted = try FaceAutoSettings.load(from: folder, completedJobs: true)
        #expect(!restarted.enabled && restarted.paused)
        #expect(restarted.sampleSeconds == 3)
    }

    @Test func explicitStartSettingsAndFailedVersionsSurviveAtomicUpdates() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var saved = FaceAutoSettings()
        saved.setEnabled(true); saved.device = "cpu"; saved.sampleSeconds = 0.5
        saved.recordFailure(file("/Тестовые фото/повреждённый 🦊.jpg"), config: "v1")
        for _ in 0..<25 {
            try saved.save(to: folder)
            let loaded = try FaceAutoSettings.load(from: folder, completedJobs: false)
            #expect(loaded.enabled && !loaded.paused && loaded.device == "cpu" && loaded.sampleSeconds == 0.5)
            #expect(loaded.failed(file("/Тестовые фото/повреждённый 🦊.jpg"), config: "v1"))
        }
        saved.setEnabled(false); try saved.save(to: folder)
        #expect(try FaceAutoSettings.load(from: folder, completedJobs: true).paused)
    }

    @Test func damagedPreferencesFailClosedInsteadOfSilentlyRestoringLegacyOptIn() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{truncated".utf8).write(to: FaceAutoSettings.file(in: folder))
        #expect(throws: (any Error).self) { try FaceAutoSettings.load(from: folder, completedJobs: true) }
        #expect(!FaceAutoSettings.validStep(.nan))
        #expect(!FaceAutoSettings.validStep(.infinity))
        #expect(!FaceAutoSettings.validStep(0))
    }

    @Test func commitsDebounceCoalesceAndWaitForTheOwnedJobWithoutStarvation() {
        var scheduler = FaceAutoSchedule(debounce: 1)
        scheduler.request(now: 0)
        let beforeDeadline = scheduler.take(now: 0.9, enabled: true, active: false)
        #expect(!beforeDeadline)
        scheduler.request(now: 0.9) // Further commits do not postpone the first deadline.
        let disabled = scheduler.take(now: 1, enabled: false, active: false)
        #expect(!disabled)
        let overlapping = scheduler.take(now: 1, enabled: true, active: true)
        #expect(!overlapping)
        let first = scheduler.take(now: 1.1, enabled: true, active: false)
        #expect(first)
        let duplicate = scheduler.take(now: 5, enabled: true, active: false)
        #expect(!duplicate)
        scheduler.request(now: 6); scheduler.request(now: 7)
        let stillActive = scheduler.take(now: 8, enabled: true, active: true)
        #expect(!stillActive)
        let next = scheduler.take(now: 9, enabled: true, active: false)
        #expect(next)
    }

    @Test func manualPauseAndShutdownCannotImmediatelyRestartFromAnOldCommit() {
        var scheduler = FaceAutoSchedule()
        scheduler.request(now: 0); scheduler.pause()
        let paused = scheduler.take(now: 5, enabled: true, active: false)
        #expect(!paused)
        scheduler.request(now: 6)
        let resumed = scheduler.take(now: 7, enabled: true, active: false)
        #expect(resumed)
        scheduler.request(now: 8); scheduler.shutdown(); scheduler.request(now: 9)
        #expect(!scheduler.requested)
        let stopped = scheduler.take(now: 100, enabled: true, active: false)
        #expect(!stopped)
    }

    @Test func onlyNewOrChangedVersionsEnterTheQueueAndGoodJobsRemainUntouched() {
        let old = file(), changed = file(size: 11), new = file("/photos/two.jpg")
        let complete = plan([old], [job(old)])
        #expect(complete.pending.isEmpty && complete.completed == 1)
        let queue = plan([changed, new], [job(old)])
        #expect(queue.pending == [changed, new] && queue.completed == 0)
        #expect(plan([old], [job(old)], config: "new-sampling").pending == [old])
        // A failed refinement is tracked separately, retaining the previous completed job and its observations.
        var saved = FaceAutoSettings(enabled: true)
        saved.recordFailure(changed, config: "v1")
        let suppressed = plan([changed], [job(old)], settings: saved)
        #expect(suppressed.pending.isEmpty && suppressed.failed == 1)
        #expect(plan([changed], [job(old)], settings: saved, retry: true).pending == [changed])
        #expect(plan([file(size: 12)], [job(old)], settings: saved).pending.count == 1)
        #expect(plan([changed], [job(old)], settings: saved, config: "v2").pending == [changed])
    }

    @Test func failedJobsDoNotHotRetryAndScopeChangesDoNotDeleteRetainedRecords() {
        let a = file(), b = file("/private/two.jpg")
        let jobs = [job(a, state: "failed"), job(b)]
        let queue = FaceAutoPlan.make(files: [a, b], jobs: jobs, settings: .init(), model: "sface", config: "v1",
                                     retryFailures: false, accepts: { $0.path.hasPrefix("/photos/") })
        #expect(queue.pending.isEmpty && queue.failed == 1 && queue.completed == 0)
        #expect(jobs.count == 2 && jobs[1].state == "done")
        #expect(plan([a], jobs, retry: true).pending == [a])
    }

    @Test func failuresKeepExactUnicodeIdentityAndOnlyTheLatestVersionPerPath() {
        let composed = file("/photos/Café.jpg"), decomposed = file("/photos/Cafe\u{301}.jpg")
        var saved = FaceAutoSettings()
        saved.recordFailure(composed, config: "v1")
        #expect(!saved.failed(decomposed, config: "v1"))
        saved.recordFailure(file(composed.path, size: 11), config: "v2")
        #expect(saved.failures.count == 1)
        #expect(!saved.failed(composed, config: "v1"))
        #expect(plan([decomposed], [job(composed)]).pending == [decomposed])
        saved.clearFailure(composed.path)
        #expect(saved.failures.isEmpty)
    }
}
