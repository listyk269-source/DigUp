import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Local, disposable previews. Keys contain exact path bytes, file version, orientation pipeline and render options.
/// A restart reuses small JPEGs; it never treats a thumbnail as evidence that a source file is still current.
public final class PreviewCache: @unchecked Sendable {
    public let directory: URL
    public static let byteLimit: Int64 = 512 * 1024 * 1024
    private let lock = NSLock()
    private var flights: [String: DispatchGroup] = [:]
    private var writes = 0
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public static func key(file: FaceFileVersion, kind: String, loc: Double?, pixels: Int) throws -> String {
        struct Identity: Encodable { let pipeline: String; let file: FaceFileVersion; let kind: String; let loc: Double?; let pixels: Int }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(Identity(pipeline: "oriented-preview-v1", file: file, kind: kind, loc: loc, pixels: pixels)))
            .map { String(format: "%02x", $0) }.joined()
    }
    public func image(key: String, make: (URL) throws -> String) throws -> (path: String, cached: Bool) {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw Database.Failure(message: "Invalid preview cache key.")
        }
        let destination = directory.appendingPathComponent(key + ".jpg")
        while true {
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                return (destination.path, true)
            }
            lock.lock()
            if let pending = flights[key] { lock.unlock(); pending.wait(); continue }
            let pending = DispatchGroup(); pending.enter(); flights[key] = pending; lock.unlock()
            defer { lock.lock(); flights.removeValue(forKey: key); lock.unlock(); pending.leave() }
            // Another owner may have finished between our first disk check and taking ownership.
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return (destination.path, true) }
            let scratch = directory.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let generated = try make(scratch)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(atPath: generated, toPath: destination.path)
            lock.lock(); writes += 1; let shouldPrune = writes % 64 == 1; lock.unlock()
            if shouldPrune { try? prune(keeping: destination) }
            return (destination.path, false)
        }
    }
    /// Oldest generated previews leave first. Never follows links or removes source media or arbitrary index files.
    public func prune(keeping: URL? = nil, byteLimit: Int64 = PreviewCache.byteLimit, fileLimit: Int = 20_000) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)).compactMap { url -> (URL, Int64, Date)? in
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "jpg", stem.count == 64, stem.allSatisfy(\.isHexDigit),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = files.reduce(Int64(0)) { $0 + $1.1 }, count = files.count
        for (file, size, _) in files where bytes > byteLimit || count > fileLimit {
            guard file != keeping else { continue }
            try FileManager.default.removeItem(at: file); bytes -= size; count -= 1
        }
    }
}
