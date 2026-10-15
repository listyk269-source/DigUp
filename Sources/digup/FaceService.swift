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
    init(directory: URL, roots: [String]?, skipped: [String], types: Set<String>) {
        self.directory = directory
        scope = Scope(roots: roots, skipped: skipped, excludedTypes: types)
    }
    func update(roots: [String]?, skipped: [String], types: Set<String>) {
        cancel()
        stateLock.withLock { scope = Scope(roots: roots, skipped: skipped, excludedTypes: types); scopeRevision &+= 1 }
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
            reply["sample_seconds"] = state["sample_seconds"] ?? 2.0
            return reply
        }
    }
    @discardableResult func cancel() -> [String: Any] {
        stateLock.withLock {
            cancellation?.cancel()
            fetcher?.cancel()
            if active { state["state"] = "cancelling" }
        }
        return status()
    }
    func start(_ request: [String: Any]) throws -> [String: Any] {
        let device = request["device"] as? String ?? "auto"
        guard ["auto", "cpu", "gpu"].contains(device) else { throw CLIError("Choose auto, CPU or GPU for face indexing.") }
        let step = request["sample_seconds"] as? Double ?? 2
        guard step.isFinite, (0.25...60).contains(step) else { throw CLIError("Video sampling must be between 0.25 and 60 seconds.") }
        let token = FaceCancellation()
        let selected: Scope? = stateLock.withLock {
            guard !active else { return nil }
            active = true; cancellation = token
            state = ["state": "running", "total": 0, "done": 0, "failed": 0, "faces": 0, "frames": 0,
                     "current_frame": 0, "total_frames": 0, "requested_device": device, "device": "unknown", "sample_seconds": step]
            return scope
        }
        guard let selected else { return status() }
        let download = request["download"] as? Bool ?? false
        Thread.detachNewThread { [self] in
            defer { stateLock.withLock { active = false; cancellation = nil; fetcher = nil } }
            do {
                try prepareModels(download: download, token: token)
                try backfill(scope: selected, device: device, step: step, token: token)
                try token.check()
                change(["state": "completed", "current_frame": 0, "total_frames": 0])
            } catch is CancellationError {
                change(["state": "cancelled"])
            } catch {
                // No file path, crop, embedding or document content is logged or copied to status.
                change(["state": "error", "error": Self.safeMessage(error)])
            }
        }
        return status()
    }

    private func change(_ values: [String: Any]) { stateLock.withLock { for (key, value) in values { state[key] = value } } }
    private func unchangedScope(_ revision: UInt64) throws {
        guard stateLock.withLock({ scopeRevision == revision }) else { throw CLIError("Selected folders changed. Repeat the face request.") }
    }
    private static func safeMessage(_ error: Error) -> String {
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
    private static func current(_ file: FaceFileVersion, scope: Scope) -> Bool {
        guard scope.accepts(file.path), scope.accepts(FolderSelection.realPath(file.path)),
              let attributes = try? FileManager.default.attributesOfItem(atPath: FileAccess.path(file.path)),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == file.size,
              let date = attributes[.modificationDate] as? Date else { return false }
        return abs(date.timeIntervalSince1970 - file.modified) < 0.001
    }

    private func backfill(scope: Scope, device: String, step: Double, token: FaceCancellation) throws {
        guard let worker = Self.worker() else { throw CLIError("The packaged face worker is missing. Reinstall DigUp with the face runtime.") }
        let sidecar = try FaceIndexStore(directory: directory)
        try sidecar.removeDeleted(retainedPaths: retainedPaths())
        let files = try indexedFiles().filter { scope.accepts($0.path) && Self.current($0, scope: scope) }
        change(["total": files.count])
        let client = try FaceWorkerClient(executable: worker, models: FaceModels.installed, device: device, token: token)
        defer { client.close() }
        let info = try client.request(["op": "info"])
        guard info["model_id"] as? String == FaceModels.modelID else {
            throw CLIError("The face worker and application model versions differ. Reinstall DigUp with matching resources.")
        }
        let actualDevice = info["device"] as? String ?? "cpu"
        change(["device": actualDevice, "device_active": actualDevice,
                "fallback_reason": info["fallback_reason"] ?? NSNull()])
        let config = "oriented-1600-actual-pts-dedup-v2;step=\(step);max-faces=32;weights=\(FaceModels.revision);worker=\(FaceModels.modelID)"
        let scratch = directory.appendingPathComponent("face-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var done = 0, failed = 0, totalFaces = 0, frames = 0
        for file in files {
            try token.check()
            if try sidecar.completed(file, model: FaceModels.modelID, config: config) {
                done += 1; totalFaces += try sidecar.count(path: file.path, model: FaceModels.modelID)
                change(["done": done, "faces": totalFaces]); continue
            }
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
                    if let output = response["faces"] as? [[String: Any]] {
                        for row in output {
                            guard let bbox = row["bbox"] as? [Double], let landmarks = row["landmarks"] as? [Double],
                                  let score = row["score"] as? Double, let vector = row["embedding"] as? [Double] else {
                                throw FaceMedia.Failure("The face runtime returned invalid data.")
                            }
                            let face = FaceObservation(bbox: bbox, landmarks: landmarks, score: score,
                                                       embedding: vector.map(Float.init), loc: loc)
                            guard face.isValid else { throw FaceMedia.Failure("The face runtime returned invalid data.") }
                            var encoded = try JSONEncoder().encode(face); encoded.append(10)
                            try stage.write(contentsOf: encoded)
                            observationCount += 1
                        }
                    } else { throw FaceMedia.Failure("The face runtime returned invalid data.") }
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
                done += 1; totalFaces += observationCount
            } catch is CancellationError { throw CancellationError() }
            catch {
                try token.check()
                failed += 1
                change(["last_issue": Self.safeMessage(error)])
                // An unsuccessful refinement must not destroy a previously valid file job. A changed file/config
                // does not satisfy completed(), so the next explicit start still retries this file.
                var hasGoodJob = false
                try sidecar.db.query("SELECT 1 FROM face_jobs WHERE path = ? AND state = 'done'", [.text(file.path)]) { _ in hasGoodJob = true }
                if !hasGoodJob {
                    try sidecar.replace(file, model: FaceModels.modelID, config: config, frames: 0, faces: [], failed: true)
                }
            }
            change(["done": done, "failed": failed, "faces": totalFaces])
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
        try unchangedScope(revision)
        return ["ok": true, "path": path, "kind": current.kind, "faces": page.filter { $0.file == current }.map(Self.fields), "total": total,
                "next_offset": next, "has_more": next < total, "indexed": indexed, "stale": !indexed]
    }

    func search(_ request: [String: Any]) throws -> [String: Any] {
        guard let id = (request["face_id"] as? NSNumber)?.int64Value else { throw CLIError("Choose a face first.") }
        let threshold = request["minimum_cosine"] as? Double ?? 0.363
        guard threshold.isFinite, (-1...1).contains(threshold) else { throw CLIError("Invalid face similarity threshold.") }
        let (selected, revision) = stateLock.withLock { (scope, scopeRevision) }
        let files = try indexedFiles()
        let byPath = Dictionary(uniqueKeysWithValues: files.map { (Data($0.path.utf8), $0) })
        let sidecar = try FaceIndexStore(directory: directory)
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
            var fields = Self.fields(target)
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
        return ["ok": true, "seed": Self.fields(seed), "hits": hits, "total": matches.count, "next_offset": next,
                "has_more": next < matches.count, "minimum_cosine": threshold, "model_id": FaceModels.modelID,
                "index_revision": indexRevision]
    }
    private static func fields(_ observation: IndexedFace) -> [String: Any] {
        ["id": observation.face.id, "face_id": observation.face.id, "path": observation.file.path, "kind": observation.file.kind,
         "bbox": observation.face.bbox, "landmarks": observation.face.landmarks, "score": observation.face.score,
         "quality": observation.face.score, "loc": observation.face.loc as Any? ?? NSNull(), "modified": observation.file.modified,
         "size": observation.file.size, "model_id": observation.model]
    }
}

private final class FaceDownloadOutcome: @unchecked Sendable { var value: FileFetcher.Outcome? }
