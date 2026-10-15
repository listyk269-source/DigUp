import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

/// Only processes owned by the face job are registered here. Cancelling never targets a process name or PID reuse.
public final class FaceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var processes: [Process] = []
    public init() {}
    public var isCancelled: Bool { lock.withLock { stopped } }
    public func check() throws { if isCancelled { throw CancellationError() } }
    public func cancel() {
        lock.withLock {
            stopped = true
            for process in processes where process.isRunning { process.terminate() }
        }
    }
    public func launch(_ process: Process) throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            try process.run()
            processes.append(process)
        }
    }
    public func forget(_ process: Process) { lock.withLock { processes.removeAll { $0 === process } } }
}

public enum FaceMedia {
    public struct Frame: Sendable {
        public let path: String
        public let seconds: Double
    }
    public enum FrameError: Error { case endOfStream }
    /// Coordinates returned by the worker refer to this oriented, downscaled image, never a distorted crop.
    public static func image(_ path: String, in folder: URL, cancellation: FaceCancellation) throws -> String {
        try cancellation.check()
        #if canImport(AVFoundation)
        let result = try ImageExtractor.prepare(URL(fileURLWithPath: path), maxPixel: 1600, minSide: 0, to: folder, png: true)
        try cancellation.check()
        return result.path
        #else
        // One cancellable decoder path also handles HEIC/TIFF/WebP and their stored orientation. In particular,
        // cancelling an unusual still image must not leave ImageExtractor's non-cancellable FFmpeg fallback alive.
        let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        _ = try run(FFmpeg.ffmpeg, ["-v", "error", "-nostdin", "-i", FileAccess.path(path), "-frames:v", "1",
            "-vf", "scale=w='min(1600,iw)':h='min(1600,ih)':force_original_aspect_ratio=decrease", "-y", FileAccess.path(out.path)],
                    cancellation: cancellation)
        try cancellation.check()
        return out.path
        #endif
    }
    public static func duration(_ path: String, cancellation: FaceCancellation) throws -> Double {
        #if canImport(AVFoundation)
        try cancellation.check()
        guard let duration = MediaInfo.duration(of: URL(fileURLWithPath: path)) else { throw Failure("Video duration is unavailable.") }
        return duration
        #else
        let data = try run(FFmpeg.ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
            "stream=duration,avg_frame_rate:format=duration", "-of", "json", FileAccess.path(path)], cancellation: cancellation)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (object["streams"] as? [[String: Any]])?.first,
              let value = (stream["duration"] as? String).flatMap(Double.init)
                ?? ((object["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init),
              value.isFinite, value > 0 else { throw Failure("Video duration is unavailable.") }
        // Container duration includes the last frame's display interval (and sometimes an audio tail). An accurate
        // forward seek inside that interval may produce no frame, especially with low-fps slideshows. Sample through
        // the estimated final video PTS, not through the container endpoint.
        let rate = (stream["avg_frame_rate"] as? String ?? "").split(separator: "/").compactMap { Double($0) }
        let fps = rate.count == 2 && rate[1] > 0 ? rate[0] / rate[1] : 0
        return fps.isFinite && fps > 0 ? max(0.000001, value - 1 / fps + 0.000001) : value
        #endif
    }
    public static func frame(_ path: String, at seconds: Double, in folder: URL, cancellation: FaceCancellation) throws -> Frame {
        try cancellation.check()
        let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        let actual: Double
        #if canImport(AVFoundation)
        actual = try runBlocking {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1600)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let (image, time) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            try ImageExtractor.write(image, to: out, png: false)
            return time.seconds
        }
        #else
        let diagnostic = FaceFrameDiagnostic()
        _ = try run(FFmpeg.ffmpeg, ["-v", "info", "-nostdin", "-copyts", "-start_at_zero", "-ss", String(seconds), "-i", FileAccess.path(path),
            "-frames:v", "1", "-vf", "showinfo,scale=w='min(1600,iw)':h='min(1600,ih)':force_original_aspect_ratio=decrease", "-y", FileAccess.path(out.path)],
                    cancellation: cancellation, diagnostic: diagnostic)
        guard FileFetcher.size(of: out) > 0 else { throw FrameError.endOfStream }
        guard let timestamp = diagnostic.timestamp, timestamp.isFinite, timestamp >= 0 else {
            try? FileManager.default.removeItem(at: out)
            throw Failure("The video decoder did not report a usable frame timestamp.")
        }
        actual = timestamp
        #endif
        try cancellation.check()
        return Frame(path: out.path, seconds: actual)
    }
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
    #if !canImport(AVFoundation)
    private static func run(_ tool: String?, _ arguments: [String], cancellation: FaceCancellation,
                            diagnostic: FaceFrameDiagnostic? = nil) throws -> Data {
        guard let tool else { throw Failure("The packaged FFmpeg/ffprobe is missing. Reinstall DigUp.") }
        let process = Process(), pipe = Pipe(), errors = Pipe(), drained = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-protocol_whitelist", "file,pipe"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = diagnostic == nil ? FileHandle.nullDevice : errors
        process.standardOutput = pipe
        try cancellation.launch(process)
        if let diagnostic {
            drained.enter()
            Thread.detachNewThread {
                defer { drained.leave() }
                while true {
                    let data = errors.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    diagnostic.append(data)
                }
            }
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit(); drained.wait(); cancellation.forget(process)
            try? pipe.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= 1 << 20 else { throw Failure("The media decoder returned too much data.") }
            data.append(chunk)
            try cancellation.check()
        }
        process.waitUntilExit()
        drained.wait()
        try cancellation.check()
        guard process.terminationStatus == 0 else { throw Failure("The media decoder could not read this file.") }
        return data
    }
    #endif
}

#if !canImport(AVFoundation)
/// Only the first actual frame PTS survives. Container metadata and paths are neither retained nor logged.
private final class FaceFrameDiagnostic: @unchecked Sendable {
    private var pending = Data()
    private(set) var timestamp: Double?
    func append(_ data: Data) {
        guard timestamp == nil else { return }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            if line.contains("showinfo"), let marker = line.range(of: "pts_time:") {
                let value = line[marker.upperBound...].prefix { !$0.isWhitespace }
                if let seconds = Double(value), seconds.isFinite { timestamp = seconds; pending.removeAll(); return }
            }
        }
        if pending.count > 32768 { pending.removeAll() }
    }
}
#endif
