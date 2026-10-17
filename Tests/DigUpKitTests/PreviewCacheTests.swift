import Foundation
import Testing
@testable import DigUpKit

@Suite struct PreviewCacheTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-preview-\(UUID().uuidString)") }
    private func key(_ path: String = "/Фото/Café 🦊.jpg", modified: Double = 1, size: Int64 = 2,
                     kind: String = "image", loc: Double? = nil, pixels: Int = 360) throws -> String {
        try PreviewCache.key(file: FaceFileVersion(path: path, kind: kind, size: size, modified: modified), kind: kind, loc: loc, pixels: pixels)
    }
    @Test func keysKeepExactUnicodeVersionsFramesAndRenderOptions() throws {
        let original = try key()
        #expect(original.count == 64)
        #expect(try original == key())
        for other in [try key("/Фото/Cafe\u{301} 🦊.jpg"), try key(modified: 2), try key(size: 3),
                      try key(kind: "video", loc: 0), try key(kind: "video", loc: 2), try key(pixels: 720)] {
            #expect(original != other)
        }
        #expect(try key(kind: "video", loc: 0) != key(kind: "video", loc: 2))
        #expect(throws: (any Error).self) { try key(modified: .nan) }
    }
    @Test func restartReusesPreviewAndFailedGenerationCanRetry() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PreviewCache(directory: root), identity = try key()
        #expect(throws: (any Error).self) { try cache.image(key: identity) { _ in throw Database.Failure(message: "decode failed") } }
        let first = try cache.image(key: identity) { scratch in
            let output = scratch.appendingPathComponent("decoded.jpg"); try Data([1, 2, 3]).write(to: output); return output.path
        }
        #expect(!first.cached)
        let restarted = try PreviewCache(directory: root).image(key: identity) { _ in throw Database.Failure(message: "must reuse") }
        #expect(restarted.cached && restarted.path == first.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        #expect(throws: (any Error).self) { try cache.image(key: "../source") { _ in "" } }
    }
    @Test func pruningIsBoundedAndPreservesUnrelatedFilesAndCurrentPreview() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PreviewCache(directory: root), unrelated = root.appendingPathComponent("user-note.txt")
        try Data([9]).write(to: unrelated)
        let first = try cache.image(key: key()) { scratch in
            let output = scratch.appendingPathComponent("a.jpg"); try Data(repeating: 1, count: 20).write(to: output); return output.path
        }
        let second = try cache.image(key: key(modified: 2)) { scratch in
            let output = scratch.appendingPathComponent("b.jpg"); try Data(repeating: 2, count: 20).write(to: output); return output.path
        }
        try cache.prune(keeping: URL(fileURLWithPath: second.path), byteLimit: 20, fileLimit: 1)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path) && FileManager.default.fileExists(atPath: unrelated.path))
    }
    @Test func simultaneousRequestsGenerateOneCompletePreview() throws {
        final class Shared: @unchecked Sendable {
            let lock = NSLock(); var generated = 0; var paths: [String] = []; var failures = 0
        }
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PreviewCache(directory: root), identity = try key(), shared = Shared()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let image = try cache.image(key: identity) { scratch in
                    shared.lock.lock(); shared.generated += 1; shared.lock.unlock()
                    Thread.sleep(forTimeInterval: 0.03)
                    let output = scratch.appendingPathComponent("a.jpg"); try Data([1, 2, 3]).write(to: output); return output.path
                }
                shared.lock.lock(); shared.paths.append(image.path); shared.lock.unlock()
            } catch { shared.lock.lock(); shared.failures += 1; shared.lock.unlock() }
        }
        #expect(shared.generated == 1 && shared.failures == 0 && shared.paths.count == 8 && Set(shared.paths).count == 1)
    }
}
