import Foundation
#if os(Windows)
import WinSDK
#endif

/// A failed attempt is separate from face_jobs: an unsuccessful refinement must preserve its last good job.
public struct FaceAutoAttempt: Codable, Sendable, Equatable {
    public let file: FaceFileVersion
    public let config: String
    public init(file: FaceFileVersion, config: String) { self.file = file; self.config = config }
    public func matches(_ file: FaceFileVersion, config: String) -> Bool {
        self.config == config && self.file.path.utf8.elementsEqual(file.path.utf8)
            && self.file.kind == file.kind && self.file.size == file.size && self.file.modified == file.modified
    }
}

/// Per-index opt-in and retry policy. No models are downloaded by enabling automatic work.
public struct FaceAutoSettings: Codable, Sendable {
    public var enabled: Bool
    public var paused: Bool
    public var device: String
    public var sampleSeconds: Double
    public var failures: [FaceAutoAttempt] = []
    public init(enabled: Bool = false, paused: Bool = false, device: String = "auto", sampleSeconds: Double = 2) {
        self.enabled = enabled; self.paused = paused; self.device = device; self.sampleSeconds = sampleSeconds
    }
    public static func file(in directory: URL) -> URL { directory.appendingPathComponent("face-auto.json") }
    public static func load(from directory: URL, completedJobs: Bool, previousStep: Double = 2) throws -> Self {
        let file = file(in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Self(enabled: completedJobs, sampleSeconds: validStep(previousStep) ? previousStep : 2)
        }
        let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: FileAccess.url(file)))
        guard ["auto", "cpu", "gpu"].contains(saved.device), validStep(saved.sampleSeconds) else {
            throw Failure("Saved face preferences are invalid. Choose face indexing settings again.")
        }
        return saved
    }
    public static func validStep(_ step: Double) -> Bool { step.isFinite && (0.25...60).contains(step) }
    public mutating func setEnabled(_ enabled: Bool) { self.enabled = enabled; paused = !enabled }
    public mutating func recordFailure(_ file: FaceFileVersion, config: String) {
        clearFailure(file.path)
        failures.append(FaceAutoAttempt(file: file, config: config))
    }
    public mutating func clearFailure(_ path: String) { failures.removeAll { $0.file.path.utf8.elementsEqual(path.utf8) } }
    public func failed(_ file: FaceFileVersion, config: String) -> Bool { failures.contains { $0.matches(file, config: config) } }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self), destination = Self.file(in: directory)
        #if os(Windows)
        // Foundation's atomic staging handle can be inherited by a concurrently launched decoder. Use its
        // noninheritable ordinary writer and a same-volume native rename; never leave a partial preferences file.
        let temporary = directory.appendingPathComponent(".face-auto-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: FileAccess.url(temporary)) }
        try data.write(to: FileAccess.url(temporary), options: .withoutOverwriting)
        let replaced = FileAccess.path(temporary.path).withCString(encodedAs: UTF16.self) { source in
            FileAccess.path(destination.path).withCString(encodedAs: UTF16.self) { target in
                for attempt in 0..<5 {
                    if MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) { return true }
                    let error = GetLastError()
                    guard error == DWORD(ERROR_SHARING_VIOLATION) || error == DWORD(ERROR_ACCESS_DENIED), attempt < 4 else { return false }
                    Thread.sleep(forTimeInterval: 0.01 * Double(1 << attempt))
                }
                return false
            }
        }
        guard replaced else { throw Failure("Face preferences could not be saved. Check access to the index folder.") }
        #else
        try data.write(to: destination, options: .atomic)
        #endif
    }
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}

/// A bounded debounce: continuous ordinary-index commits coalesce without postponing face work forever.
/// The owner serializes access and supplies a monotonic clock; no timer or native worker is created here.
public struct FaceAutoSchedule: Sendable {
    private var due: TimeInterval?
    private var stopped = false
    public let debounce: TimeInterval
    public init(debounce: TimeInterval = 1) { self.debounce = debounce }
    public var requested: Bool { due != nil }
    public mutating func request(now: TimeInterval) { if !stopped, due == nil { due = now + debounce } }
    public mutating func take(now: TimeInterval, enabled: Bool, active: Bool) -> Bool {
        guard !stopped, enabled, !active, let due, now >= due else { return false }
        self.due = nil
        return true
    }
    public mutating func pause() { due = nil }
    public mutating func shutdown() { stopped = true; due = nil }
}

public struct FaceAutoJob: Sendable {
    public let file: FaceFileVersion
    public let model: String
    public let config: String
    public let state: String
    public init(file: FaceFileVersion, model: String, config: String, state: String) {
        self.file = file; self.model = model; self.config = config; self.state = state
    }
}

/// Queue selection never edits jobs or annotations. Disk validation is needed only for pending candidates.
public struct FaceAutoPlan: Sendable {
    public var pending: [FaceFileVersion] = []
    public var completed = 0
    public var failed = 0
    public static func make(files: [FaceFileVersion], jobs: [FaceAutoJob], settings: FaceAutoSettings,
                            model: String, config: String, retryFailures: Bool,
                            accepts: (FaceFileVersion) -> Bool) -> Self {
        let existing = Dictionary(jobs.map { (Data($0.file.path.utf8), $0) }, uniquingKeysWith: { _, last in last })
        var plan = Self()
        for file in files where accepts(file) {
            let old = existing[Data(file.path.utf8)]
            let same = old.map { $0.model == model && FaceAutoAttempt(file: $0.file, config: $0.config).matches(file, config: config) } ?? false
            if same, old?.state == "done" { plan.completed += 1; continue }
            if !retryFailures, (same && old?.state == "failed") || settings.failed(file, config: config) {
                plan.failed += 1; continue
            }
            plan.pending.append(file)
        }
        return plan
    }
}
