import DigUpKit
import Foundation

/// Local, opt-in sidecar indexing. State is guarded by stateLock; SQLite and native inference live on their owning thread.
final class FaceService: @unchecked Sendable {
    struct Scope: Sendable {
        let roots: [String]?
        let skipped: [String]
        let excludedTypes: Set<String>
        func accepts(_ path: String) -> Bool {
            (roots.map { FolderSelection.isSearched(path, folders: $0, skipped: skipped) } ?? true)
                && !excludedTypes.contains((path as NSString).pathExtension.lowercased())
        }
    }
    private let directory: URL
    private let stateLock = NSLock()
    private var scope: Scope
    private var scopeRevision: UInt64 = 0
    private var state: [String: Any] = ["state": "idle", "total": 0, "done": 0, "failed": 0, "faces": 0, "frames": 0,
                                      "current_frame": 0, "total_frames": 0, "requested_device": "auto", "device": "unknown"]
    private var cancellation: FaceCancellation?
    private var fetcher: FileFetcher?
    private var active = false
    private var verifiedModels = false
    private var preferences = FaceAutoSettings()
    private var schedule = FaceAutoSchedule()
    private var monitoring = false
    private var closed = false
    private var autoBlocked = false
    private var manualStart = false
    private var sourceRevision: UInt64 = 0
    private let wake = DispatchSemaphore(value: 0)
    private let jobs = DispatchGroup()
    let suggestionSummary = FaceSuggestionSummaryCache()

    init(directory: URL, roots: [String]?, skipped: [String], types: Set<String>) {
        self.directory = directory
        scope = Scope(roots: roots, skipped: skipped, excludedTypes: types)
        do {
            var completed = false, step = 2.0
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(FaceIndexStore.name).path) {
                let sidecar = try Database(path: directory.appendingPathComponent(FaceIndexStore.name).path)
                try sidecar.query("SELECT config FROM face_jobs WHERE state = 'done' ORDER BY completed DESC LIMIT 1") { row in
                    completed = true
                    if let config = row.text(0), let raw = config.split(separator: ";").first(where: { $0.hasPrefix("step=") }),
                       let value = Double(raw.dropFirst(5)), FaceAutoSettings.validStep(value) { step = value }
                }
            }
            preferences = try FaceAutoSettings.load(from: directory, completedJobs: completed, previousStep: step)
            // Persist the legacy opt-in decision once. A later deletion of face jobs must not silently opt someone out.
            if completed, !FileManager.default.fileExists(atPath: FaceAutoSettings.file(in: directory).path) {
                try preferences.save(to: directory)
            }
        } catch {
            preferences = FaceAutoSettings()
            state["auto_error"] = "Saved face preferences could not be read. Choose face indexing settings again."
        }
    }
    func update(roots: [String]?, skipped: [String], types: Set<String>) {
        stateLock.withLock {
            cancellation?.cancel(); fetcher?.cancel()
            scope = Scope(roots: roots, skipped: skipped, excludedTypes: types); scopeRevision &+= 1
            state["pending"] = 0; state["previously_completed"] = 0
            schedule.request(now: ProcessInfo.processInfo.systemUptime)
            if active { state["state"] = "cancelling" }
        }
        suggestionSummary.invalidate(); wake.signal()
    }
    func status() -> [String: Any] {
        stateLock.withLock {
            var reply = state
            reply["ok"] = true
            reply["models_ready"] = verifiedModels || FaceModels.complete(in: FaceModels.installed)
            reply["worker_available"] = Self.worker() != nil
            reply["backend_ready"] = Self.worker() != nil
            reply["device_active"] = state["device"] ?? "unknown"
            reply["active"] = active
            reply["model_id"] = FaceModels.modelID
            reply["sample_seconds"] = state["sample_seconds"] ?? preferences.sampleSeconds
            reply["auto_enabled"] = preferences.enabled
            reply["auto_paused"] = preferences.paused
            reply["auto_device"] = preferences.device
            reply["auto_sample_seconds"] = preferences.sampleSeconds
            reply["auto_pending"] = state["pending"] ?? 0
            reply["pending"] = state["pending"] ?? 0
            reply["previously_completed"] = state["previously_completed"] ?? 0
            reply["auto_state"] = preferences.paused ? "paused" : !preferences.enabled ? "disabled"
                : active ? "running" : state["auto_state"] ?? "waiting_for_index"
            reply["auto_error"] = state["auto_error"] ?? NSNull()
            return reply
        }
    }
    @discardableResult func cancel() -> [String: Any] {
        stateLock.withLock {
            preferences.setEnabled(false); schedule.pause()
            do { try preferences.save(to: directory) }
            catch { state["auto_error"] = "The pause could not be saved. Check access to the index folder before restarting DigUp." }
            cancellation?.cancel()
            fetcher?.cancel()
            if active { state["state"] = "cancelling" }
        }
        return status()
    }

    /// Quitting or changing the scope cancels owned work without turning a persistent opt-in into a manual pause.
    func shutdown() {
        stateLock.withLock {
            closed = true; schedule.shutdown(); cancellation?.cancel(); fetcher?.cancel()
        }
        suggestionSummary.cancel(); wake.signal()
        _ = jobs.wait(timeout: .now() + 1.5)
    }

    func automatic(_ request: [String: Any]) throws -> [String: Any] {
        guard let enabled = request["enabled"] as? Bool else { throw CLIError("Choose whether automatic face indexing is enabled.") }
        let (device, step) = try settings(request)
        try stateLock.withLock {
            guard !closed else { throw CLIError("Face indexing is shutting down.") }
            let changed = preferences.device != device || preferences.sampleSeconds != step
            var updated = preferences; updated.setEnabled(enabled); updated.device = device; updated.sampleSeconds = step
            try updated.save(to: directory); preferences = updated
            autoBlocked = false; state.removeValue(forKey: "auto_error")
            if !enabled || changed { cancellation?.cancel(); fetcher?.cancel() }
            if enabled { schedule.request(now: ProcessInfo.processInfo.systemUptime) } else { schedule.pause() }
            if active, !enabled || changed { state["state"] = "cancelling" }
        }
        wake.signal()
        return status()
    }

    private func settings(_ request: [String: Any]) throws -> (String, Double) {
        let saved = stateLock.withLock { preferences }
        let device = request["device"] as? String ?? saved.device
        guard ["auto", "cpu", "gpu"].contains(device) else { throw CLIError("Choose auto, CPU or GPU for face indexing.") }
        let step = request["sample_seconds"] as? Double ?? saved.sampleSeconds
        guard FaceAutoSettings.validStep(step) else { throw CLIError("Video sampling must be between 0.25 and 60 seconds.") }
        return (device, step)
    }
    func start(_ request: [String: Any]) throws -> [String: Any] {
        let (device, step) = try settings(request)
        let start = try stateLock.withLock {
            guard !closed else { throw CLIError("Face indexing is shutting down.") }
            guard !active, !manualStart else { return false }
            var updated = preferences; updated.setEnabled(true); updated.device = device; updated.sampleSeconds = step
            try updated.save(to: directory); preferences = updated
            autoBlocked = false; state.removeValue(forKey: "auto_error")
            manualStart = true
            return true
        }
        if start { launch(device: device, step: step, download: request["download"] as? Bool ?? false, automatic: false) }
        return status()
    }

    private func launch(device: String, step: Double, download: Bool, automatic: Bool, expectedScope: UInt64? = nil) {
        let token = FaceCancellation()
        let selected: Scope? = stateLock.withLock {
            guard !closed, !active, !automatic || (preferences.enabled && !preferences.paused) else { return nil }
            guard !automatic || !manualStart else { return nil }
            if let expectedScope {
                guard scopeRevision == expectedScope, preferences.device == device, preferences.sampleSeconds == step else { return nil }
            }
            active = true; manualStart = false; cancellation = token
            let previous = state["previously_completed"] ?? 0, pending = state["pending"] ?? 0
            state = ["state": "running", "total": 0, "done": 0, "failed": 0, "faces": 0, "frames": 0,
                     "current_frame": 0, "total_frames": 0, "requested_device": device, "device": "unknown", "sample_seconds": step,
                     "previously_completed": previous, "pending": pending, "automatic": automatic]
            jobs.enter()
            return scope
        }
        guard let selected else { return }
        Thread.detachNewThread { [self] in
            defer {
                stateLock.withLock {
                    active = false; cancellation = nil; fetcher = nil
                    schedule.request(now: ProcessInfo.processInfo.systemUptime)
                }
                wake.signal(); jobs.leave()
            }
            do {
                try prepareModels(download: download, token: token)
                try backfill(scope: selected, device: device, step: step, token: token, automatic: automatic)
                try token.check()
                change(["state": "completed", "current_frame": 0, "total_frames": 0])
            } catch is CancellationError {
                change(["state": "cancelled"])
            } catch {
                // No file path, crop, embedding or document content is logged or copied to status.
                stateLock.withLock { autoBlocked = true }
                change(["state": "error", "error": Self.safeMessage(error), "auto_state": "error", "auto_error": Self.safeMessage(error)])
            }
        }
    }

    /// The ordinary index owns file discovery. Observe its commits without opening a decoder, loading weights,
    /// or repeatedly walking user folders. A separate connection is confined to this monitor thread.
    func startMonitoring() {
        let start = stateLock.withLock {
            guard !closed, !monitoring else { return false }
            monitoring = true; schedule.request(now: ProcessInfo.processInfo.systemUptime)
            return true
        }
        guard start else { return }
        Thread.detachNewThread { [self] in
            var database: Database?, previous: Int64?
            while !stateLock.withLock({ closed }) {
                do {
                    if database == nil { database = try Database(path: directory.appendingPathComponent(IndexStore.mainFile).path) }
                    var version: Int64 = 0
                    try database?.query("PRAGMA data_version") { version = $0.int(0) }
                    if previous != version {
                        previous = version
                        stateLock.withLock {
                            sourceRevision &+= 1; schedule.request(now: ProcessInfo.processInfo.systemUptime)
                        }
                        suggestionSummary.invalidate()
                    }
                    let check = stateLock.withLock {
                        if state["auto_state"] as? String == "waiting_for_models", FaceModels.complete(in: FaceModels.installed) {
                            schedule.request(now: ProcessInfo.processInfo.systemUptime)
                        }
                        return schedule.take(now: ProcessInfo.processInfo.systemUptime,
                            enabled: preferences.enabled && !preferences.paused && !autoBlocked, active: active)
                    }
                    if check { try checkAutomaticWork() }
                } catch {
                    stateLock.withLock {
                        // A temporarily busy ordinary index must not permanently disable an existing opt-in.
                        // Retry metadata after the bounded debounce; only launch() latches native/model errors.
                        schedule.request(now: ProcessInfo.processInfo.systemUptime)
                        state["auto_state"] = "error"
                        state["auto_error"] = Self.safeMessage(error)
                    }
                }
                _ = wake.wait(timeout: .now() + 1)
            }
        }
    }

    private func checkAutomaticWork() throws {
        let (selected, revision, saved) = stateLock.withLock { (scope, scopeRevision, preferences) }
        let config = Self.configuration(step: saved.sampleSeconds)
        var plan = try plan(scope: selected, settings: saved, config: config, retryFailures: false)
        plan.pending = plan.pending.filter { Self.current($0, scope: selected) }
        let proceed = stateLock.withLock {
            guard !closed, !active, !autoBlocked, scopeRevision == revision, preferences.enabled, !preferences.paused,
                  preferences.device == saved.device, preferences.sampleSeconds == saved.sampleSeconds else { return false }
            if state["auto_state"] as? String == "error" { state.removeValue(forKey: "auto_error") }
            state["pending"] = plan.pending.count; state["previously_completed"] = plan.completed
            state["auto_failed"] = plan.failed
            guard !plan.pending.isEmpty else { state["auto_state"] = "waiting_for_index"; return false }
            guard FaceModels.complete(in: FaceModels.installed) else { state["auto_state"] = "waiting_for_models"; return false }
            state["auto_state"] = "ready"
            return true
        }
        if proceed { launch(device: saved.device, step: saved.sampleSeconds, download: false, automatic: true, expectedScope: revision) }
    }

    func suggestionContext() -> (directory: URL, scope: Scope, revision: UInt64, sourceRevision: UInt64) {
        stateLock.withLock { (directory, scope, scopeRevision, sourceRevision) }
    }
    func checkSuggestionScope(_ revision: UInt64, sourceRevision: UInt64) throws {
        guard stateLock.withLock({ !closed && scopeRevision == revision && self.sourceRevision == sourceRevision }) else {
            throw CLIError("Selected folders or indexed files changed. Refresh the face suggestions.")
        }
    }

    private func change(_ values: [String: Any]) { stateLock.withLock { for (key, value) in values { state[key] = value } } }
    private func unchangedScope(_ revision: UInt64) throws {
        guard stateLock.withLock({ scopeRevision == revision }) else { throw CLIError("Selected folders changed. Repeat the face request.") }
    }
    private static func safeMessage(_ error: Error) -> String {
        if let error = error as? FaceWorkerProtocol.RuntimeFailure { return error.description }
        if let error = error as? FaceWorkerProtocol.FileFailure { return error.description }
        if let error = error as? CLIError { return error.description }
        if let error = error as? FaceMedia.Failure { return error.description }
        return "Face indexing could not finish. Check the model files, packaged runtime and selected-folder access, then retry."
    }

    private func prepareModels(download: Bool, token: FaceCancellation) throws {
        let folder = FaceModels.installed
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = FaceModels.all.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for file in FaceModels.all {
            try token.check()
            let final = folder.appendingPathComponent(file.name)
            if ModelFiles.isComplete(file, in: folder), try ModelFiles.sha256(of: final) == file.sha256 {
                completed += file.bytes
                continue
            }
            guard download else { throw CLIError("Face models are missing or damaged. Start face indexing with model download enabled.") }
            change(["state": "downloading", "download_bytes": completed, "download_total": total])
            var succeeded = false
            for attempt in 0..<3 {
                try token.check()
                let box = FaceDownloadOutcome(), semaphore = DispatchSemaphore(value: 0), before = completed
                let downloader = FileFetcher(file: file, folder: folder, progress: { [self] written in
                    change(["download_bytes": before + written, "download_total": total])
                }, waiting: {}, done: { outcome in box.value = outcome; semaphore.signal() })
                try stateLock.withLock {
                    try token.check()
                    fetcher = downloader
                    downloader.start()
                }
                while semaphore.wait(timeout: .now() + 0.2) == .timedOut { try token.check() }
                try token.check()
                switch box.value {
                case .downloaded(let partial):
                    if try ModelFiles.sha256(of: partial) == file.sha256 {
                        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
                        try FileManager.default.moveItem(at: partial, to: final)
                        succeeded = true
                    } else { try? FileManager.default.removeItem(at: partial) }
                case .failed(_, let retry):
                    if !retry { throw CLIError("The face model download failed. Check network access and free disk space, then retry.") }
                case nil: break
                }
                if succeeded { break }
                if attempt < 2 {
                    for _ in 0..<10 { try token.check(); Thread.sleep(forTimeInterval: 0.2) }
                }
            }
            guard succeeded else { throw CLIError("The face model download failed after three attempts. Retry to resume the partial download.") }
            completed += file.bytes
        }
        stateLock.withLock { verifiedModels = true; fetcher = nil }
        change(["state": "running", "download_bytes": total, "download_total": total])
    }

    private func indexedFiles() throws -> [FaceFileVersion] {
        let database = try Database(path: directory.appendingPathComponent(IndexStore.mainFile).path)
        var files: [FaceFileVersion] = []
        try database.query("SELECT path, kind, size, mtime FROM files WHERE kind IN ('image', 'screenshot', 'video') AND state IN ('done', 'partial') ORDER BY path") { row in
            if let path = row.text(0), let kind = row.text(1) {
                files.append(FaceFileVersion(path: path, kind: kind, size: row.int(2), modified: row.double(3)))
            }
        }
        return files
    }
    private func retainedPaths() throws -> Set<Data> {
        let database = try Database(path: directory.appendingPathComponent(IndexStore.mainFile).path)
        var paths = Set<Data>()
        try database.query("SELECT path FROM files") { if let path = $0.text(0) { paths.insert(Data(path.utf8)) } }
        return paths
    }
    static func current(_ file: FaceFileVersion, scope: Scope) -> Bool {
        guard scope.accepts(file.path), scope.accepts(FolderSelection.realPath(file.path)),
              let attributes = try? FileManager.default.attributesOfItem(atPath: FileAccess.path(file.path)),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == file.size,
              let date = attributes[.modificationDate] as? Date else { return false }
        return abs(date.timeIntervalSince1970 - file.modified) < 0.001
    }

    private static func configuration(step: Double) -> String {
        "oriented-1600-actual-pts-dedup-v2;step=\(step);max-faces=32;weights=\(FaceModels.revision);worker=\(FaceModels.modelID)"
    }

    private func plan(scope: Scope, settings: FaceAutoSettings, config: String, retryFailures: Bool) throws -> FaceAutoPlan {
        var jobs: [FaceAutoJob] = []
        let path = directory.appendingPathComponent(FaceIndexStore.name)
        if FileManager.default.fileExists(atPath: path.path) {
            let database = try Database(path: path.path)
            try database.query("SELECT path,kind,size,modified,model,config,state FROM face_jobs") { row in
                guard let path = row.text(0), let kind = row.text(1), let model = row.text(4),
                      let config = row.text(5), let state = row.text(6) else { return }
                jobs.append(FaceAutoJob(file: FaceFileVersion(path: path, kind: kind, size: row.int(2), modified: row.double(3)),
                                        model: model, config: config, state: state))
            }
        }
        return FaceAutoPlan.make(files: try indexedFiles(), jobs: jobs, settings: settings,
            model: FaceModels.modelID, config: config, retryFailures: retryFailures, accepts: { scope.accepts($0.path) })
    }

    private func rememberFailure(_ file: FaceFileVersion, config: String) throws {
        try stateLock.withLock {
            var updated = preferences; updated.recordFailure(file, config: config)
            try updated.save(to: directory); preferences = updated
        }
    }
    private func forgetFailure(_ path: String) throws {
        try stateLock.withLock {
            guard preferences.failures.contains(where: { $0.file.path.utf8.elementsEqual(path.utf8) }) else { return }
            var updated = preferences; updated.clearFailure(path)
            try updated.save(to: directory); preferences = updated
        }
    }

    private func backfill(scope: Scope, device: String, step: Double, token: FaceCancellation, automatic: Bool) throws {
        guard let worker = Self.worker() else { throw CLIError("The packaged face worker is missing. Reinstall DigUp with the face runtime.") }
        let sidecar = try FaceIndexStore(directory: directory)
        try sidecar.removeDeleted(retainedPaths: retainedPaths())
        let config = Self.configuration(step: step)
        let initial = try plan(scope: scope, settings: stateLock.withLock { preferences }, config: config, retryFailures: !automatic)
        var files = initial.pending.filter { Self.current($0, scope: scope) }
        change(["total": files.count, "pending": files.count, "previously_completed": initial.completed, "auto_failed": initial.failed])
        // An explicit manual start still reports the actual backend, including for a fully completed index.
        guard !automatic || !files.isEmpty else { return }
        let client = try FaceWorkerClient(executable: worker, models: FaceModels.installed, device: device, token: token)
        defer { client.close() }
        let info = try client.request(["op": "info"])
        guard info["model_id"] as? String == FaceModels.modelID else {
            throw CLIError("The face worker and application model versions differ. Reinstall DigUp with matching resources.")
        }
        let actualDevice = info["device"] as? String ?? "cpu"
        change(["device": actualDevice, "device_active": actualDevice,
                "fallback_reason": info["fallback_reason"] ?? NSNull()])
        let scratch = directory.appendingPathComponent("face-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var done = 0, failed = 0, totalFaces = 0, frames = 0
        var cursor = 0
        var attempted: [Data: FaceAutoAttempt] = [:]
        while cursor < files.count {
            let file = files[cursor]; cursor += 1
            attempted[Data(file.path.utf8)] = FaceAutoAttempt(file: file, config: config)
            try token.check()
            do {
                guard Self.current(file, scope: scope) else { throw FaceMedia.Failure("The file changed before face indexing.") }
                let duration = file.kind == "video" ? try FaceMedia.duration(file.path, cancellation: token) : 0
                guard duration < Double(Int.max) * step else { throw FaceMedia.Failure("The video duration is invalid.") }
                let count = file.kind == "video" ? max(1, Int(ceil(duration / step))) : 1
                let staged = scratch.appendingPathComponent(UUID().uuidString + ".jsonl")
                _ = FileManager.default.createFile(atPath: staged.path, contents: nil)
                let stage = try FileHandle(forWritingTo: staged)
                defer { try? stage.close(); try? FileManager.default.removeItem(at: staged) }
                var observationCount = 0, completedFrames = 0
                var lastFrameTime: Double?
                change(["current_frame": 0, "total_frames": count])
                for frame in 0..<count {
                    try token.check()
                    var loc: Double?
                    let prepared: String
                    if file.kind == "video" {
                        let decoded: FaceMedia.Frame
                        do { decoded = try FaceMedia.frame(file.path, at: Double(frame) * step, in: scratch, cancellation: token) }
                        catch FaceMedia.FrameError.endOfStream {
                            guard completedFrames > 0 else { throw FaceMedia.Failure("The video has no readable frames.") }
                            break
                        }
                        prepared = decoded.path; loc = decoded.seconds
                        if let lastFrameTime, abs(lastFrameTime - decoded.seconds) < 0.000001 {
                            try? FileManager.default.removeItem(atPath: FileAccess.path(prepared))
                            change(["current_frame": frame + 1])
                            continue
                        }
                        lastFrameTime = decoded.seconds
                    } else { prepared = try FaceMedia.image(file.path, in: scratch, cancellation: token) }
                    defer { try? FileManager.default.removeItem(atPath: FileAccess.path(prepared)) }
                    let response = try client.request(["op": "analyze", "path": prepared, "max_faces": 32])
                    for face in try FaceWorkerProtocol.observations(response, location: loc) {
                        var encoded = try JSONEncoder().encode(face); encoded.append(10)
                        try stage.write(contentsOf: encoded)
                        observationCount += 1
                    }
                    frames += 1
                    completedFrames += 1
                    change(["frames": frames, "current_frame": frame + 1, "device": response["device"] ?? actualDevice,
                            "fallback_reason": response["fallback_reason"] ?? info["fallback_reason"] ?? NSNull()])
                }
                try token.check()
                guard Self.current(file, scope: scope) else { throw FaceMedia.Failure("The file changed during face indexing.") }
                try stage.synchronize()
                try stage.close()
                try sidecar.replaceStaged(file, model: FaceModels.modelID, config: config, frames: completedFrames,
                                          staged: staged, cancellation: token)
                try forgetFailure(file.path)
                done += 1; totalFaces += observationCount
            } catch is CancellationError { throw CancellationError() }
            catch let error as FaceWorkerProtocol.RuntimeFailure {
                // The analysis result is unknown. Keep this version and every remaining file pending;
                // a dead/protocol-broken shared worker must not poison the per-file retry ledger.
                try token.check()
                throw error
            }
            catch {
                try token.check()
                failed += 1
                change(["last_issue": Self.safeMessage(error)])
                // Persist a version/config-specific failed attempt even when a previous good job is retained.
                // Only a new version, settings change, or explicit manual start retries it.
                try rememberFailure(file, config: config)
                // An unsuccessful refinement must not destroy a previously valid file job. A changed file/config
                // does not satisfy completed(), so the next explicit start still retries this file.
                var hasGoodJob = false
                try sidecar.db.query("SELECT 1 FROM face_jobs WHERE path = ? AND state = 'done'", [.text(file.path)]) { _ in hasGoodJob = true }
                if !hasGoodJob {
                    try sidecar.replace(file, model: FaceModels.modelID, config: config, frames: 0, faces: [], failed: true)
                }
            }
            if cursor == files.count {
                try token.check()
                // Ordinary indexing can commit more files during this sweep. Extend the same owned worker's
                // queue before it exits; a final racing commit is also caught by the monitor's data_version.
                let fresh = try plan(scope: scope, settings: stateLock.withLock { preferences }, config: config, retryFailures: !automatic)
                files += fresh.pending.filter {
                    attempted[Data($0.path.utf8)]?.matches($0, config: config) != true && Self.current($0, scope: scope)
                }
            }
            change(["done": done, "failed": failed, "faces": totalFaces, "total": files.count, "pending": files.count - cursor])
        }
    }

    /// Explicit locations only; neither PATH nor the current working directory supplies release executables.
    static func worker(environment: [String: String] = ProcessInfo.processInfo.environment, executable: URL? = Bundle.main.executableURL) -> URL? {
        var folders: [URL] = []
        if let override = environment["DIGUP_FACE_WORKER"], !override.isEmpty {
            let path = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        if let executable {
            let parent = executable.deletingLastPathComponent()
            folders += [parent.appendingPathComponent("faces"), parent, parent.appendingPathComponent("../faces").standardizedFileURL]
        }
        #if os(Windows)
        let program = "digup-face-worker.exe"
        #else
        let program = "digup-face-worker"
        #endif
        return folders.map { $0.appendingPathComponent(program) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func file(_ request: [String: Any]) throws -> [String: Any] {
        guard let path = request["path"] as? String else { throw CLIError("Choose an indexed image or video.") }
        let (selected, revision) = stateLock.withLock { (scope, scopeRevision) }
        guard selected.accepts(path), selected.accepts(FolderSelection.realPath(path)) else { throw CLIError("This file is outside the selected folders.") }
        let files = try indexedFiles(), current = files.first { $0.path.utf8.elementsEqual(path.utf8) }
        guard let current, Self.current(current, scope: selected) else { throw CLIError("The file changed or is unavailable. Finish indexing and retry.") }
        let sidecar = try FaceIndexStore(directory: directory)
        var indexed = false
        try sidecar.db.query("SELECT 1 FROM face_jobs WHERE path = ? AND kind = ? AND size = ? AND modified = ? AND model = ? AND state = 'done'",
                             [.text(path), .text(current.kind), .int(current.size), .double(current.modified), .text(FaceModels.modelID)]) { _ in indexed = true }
        let total = indexed ? try sidecar.count(path: path, model: FaceModels.modelID) : 0
        let offset = min(max(request["offset"] as? Int ?? 0, 0), total)
        let limit = min(max(request["limit"] as? Int ?? 60, 1), 200), next = min(total, offset + limit)
        let page = indexed ? try sidecar.observations(path: path, model: FaceModels.modelID, offset: offset, limit: limit) : []
        let peopleStore = FacePeopleStore(index: sidecar)
        let names = Dictionary(uniqueKeysWithValues: try peopleStore.people().map { ($0.id, $0) })
        let labeled = try page.filter { $0.file == current }.map { try Self.labeledFields($0, store: peopleStore, people: names) }
        try unchangedScope(revision)
        return ["ok": true, "path": path, "kind": current.kind, "faces": labeled, "total": total,
                "next_offset": next, "has_more": next < total, "indexed": indexed, "stale": !indexed,
                "index_revision": try sidecar.revision(), "people_revision": try peopleStore.revision()]
    }

    func search(_ request: [String: Any]) throws -> [String: Any] {
        guard let id = (request["face_id"] as? NSNumber)?.int64Value else { throw CLIError("Choose a face first.") }
        let threshold = request["minimum_cosine"] as? Double ?? 0.363
        guard threshold.isFinite, (-1...1).contains(threshold) else { throw CLIError("Invalid face similarity threshold.") }
        let (selected, revision) = stateLock.withLock { (scope, scopeRevision) }
        let files = try indexedFiles()
        let byPath = Dictionary(uniqueKeysWithValues: files.map { (Data($0.path.utf8), $0) })
        let sidecar = try FaceIndexStore(directory: directory)
        let peopleStore = FacePeopleStore(index: sidecar)
        let names = Dictionary(uniqueKeysWithValues: try peopleStore.people().map { ($0.id, $0) })
        let indexRevision = try sidecar.revision()
        if (request["offset"] as? Int ?? 0) > 0,
           (request["index_revision"] as? NSNumber)?.int64Value != indexRevision {
            return ["ok": false, "expired": true, "error": "Face index changed. Run the face search again."]
        }
        guard let seed = try sidecar.observations(model: FaceModels.modelID, id: id).first,
              byPath[Data(seed.file.path.utf8)] == seed.file, Self.current(seed.file, scope: selected) else {
            throw CLIError("This face changed or is outside the selected folders. Choose it again.")
        }
        var matches: [(id: Int64, cosine: Double)] = []
        var versions: [Data: Bool] = [:]
        try sidecar.forEach(model: FaceModels.modelID) { target in
            let key = Data(target.file.path.utf8)
            let valid = versions[key] ?? (byPath[key] == target.file && Self.current(target.file, scope: selected))
            versions[key] = valid
            guard valid, target.face.id != id, let cosine = FaceIndexStore.cosine(seed.face.embedding, target.face.embedding), cosine >= threshold else { return }
            matches.append((target.face.id, cosine))
        }
        matches.sort { $0.cosine == $1.cosine ? $0.id < $1.id : $0.cosine > $1.cosine }
        let offset = min(max(request["offset"] as? Int ?? 0, 0), matches.count)
        let limit = min(max(request["limit"] as? Int ?? 40, 1), 200), next = min(matches.count, offset + limit)
        let hits = try matches[offset..<next].compactMap { match -> [String: Any]? in
            guard let target = try sidecar.observations(model: FaceModels.modelID, id: match.id).first,
                  Self.current(target.file, scope: selected) else { return nil }
            var fields = try Self.labeledFields(target, store: peopleStore, people: names)
            fields["name"] = (target.file.path as NSString).lastPathComponent
            fields["cosine"] = match.cosine; fields["score"] = match.cosine
            fields["match_types"] = ["face"]
            fields["match_evidence"] = [["type": "face", "cosine": match.cosine, "loc": target.face.loc as Any? ?? NSNull(),
                                          "seed_loc": seed.face.loc as Any? ?? NSNull(), "bbox": target.face.bbox, "seed_bbox": seed.face.bbox]]
            fields["info"] = [String: String]()
            return fields
        }
        guard try sidecar.revision() == indexRevision else {
            return ["ok": false, "expired": true, "error": "Face index changed. Run the face search again."]
        }
        try unchangedScope(revision)
        return ["ok": true, "seed": try Self.labeledFields(seed, store: peopleStore, people: names), "hits": hits, "total": matches.count, "next_offset": next,
                "has_more": next < matches.count, "minimum_cosine": threshold, "model_id": FaceModels.modelID,
                "index_revision": indexRevision, "people_revision": try peopleStore.revision()]
    }
    func people(_ op: String, _ request: [String: Any]) throws -> [String: Any] {
        let (selected, revision) = stateLock.withLock { (scope, scopeRevision) }
        // Album access usually touches a tiny fraction of the main index. Resolve only the saved files that
        // the handler asks about; do not rebuild the complete media-version dictionary on every page/click.
        let main = try Database(path: directory.appendingPathComponent(IndexStore.mainFile).path)
        var checked = Set<Data>(), byPath: [Data: FaceFileVersion] = [:], reachable: [Data: Bool] = [:]
        var lookupFailure: Error?
        var capturedDates: [Data: String] = [:]
        let handler = try FacePeopleService(directory: directory, acceptsCurrent: { file in
            let key = Data(file.path.utf8)
            if checked.insert(key).inserted {
                do {
                    try main.query("SELECT kind,size,mtime,CASE WHEN json_valid(info) THEN json_extract(info, '$.taken') END FROM files WHERE path = ? AND kind IN ('image','screenshot','video') AND state IN ('done','partial')", [.text(file.path)]) { row in
                        byPath[key] = FaceFileVersion(path: file.path, kind: row.text(0) ?? "", size: row.int(1), modified: row.double(2))
                        capturedDates[key] = row.text(3)
                    }
                } catch { lookupFailure = error }
            }
            guard byPath[key] == file else { return false }
            if let value = reachable[key] { return value }
            let value = Self.current(file, scope: selected); reachable[key] = value; return value
        }, acceptsScope: { file in
            selected.accepts(file.path) && selected.accepts(FolderSelection.realPath(file.path))
        }, checkScope: { [self] in
            if let lookupFailure { throw lookupFailure }
            try unchangedScope(revision)
        }, mediaDate: { FacePeopleAlbum.date(captured: capturedDates[Data($0.path.utf8)], modified: $0.modified) })
        return try handler.handle(op, request)
    }
    static func fields(_ observation: IndexedFace) -> [String: Any] {
        ["id": observation.face.id, "face_id": observation.face.id, "path": observation.file.path, "kind": observation.file.kind,
         "bbox": observation.face.bbox, "landmarks": observation.face.landmarks, "score": observation.face.score,
         "quality": observation.face.score, "loc": observation.face.loc as Any? ?? NSNull(), "modified": observation.file.modified,
         "size": observation.file.size, "model_id": observation.model]
    }
    static func labeledFields(_ observation: IndexedFace, store: FacePeopleStore, people: [String: FacePerson]) throws -> [String: Any] {
        var result = fields(observation)
        let snapshot = FacePersonSnapshot(observation)
        let annotations = try store.annotations(anchor: snapshot.anchor)
        let assigned = annotations.first { $0.state == "assigned" }.flatMap { people[$0.personID] }
        result["anchor_key"] = snapshot.anchor
        result["person"] = assigned.map { ["id": $0.id, "name": $0.name] } as Any? ?? NSNull()
        result["rejected_people"] = annotations.filter { $0.state == "rejected" }.compactMap { annotation -> [String: String]? in
            guard let person = people[annotation.personID] else { return nil }
            return ["id": person.id, "name": person.name]
        }
        return result
    }
}

private final class FaceDownloadOutcome: @unchecked Sendable { var value: FileFetcher.Outcome? }
