import Foundation
import Testing
@testable import DigUpKit
#if os(Windows)
import WinSDK
#endif

/// Real filesystem, extraction, SQLite/FTS5 and reconciliation checks; they deliberately need no embedding model.
@Suite struct PortableReleaseTests {
    #if !canImport(ImageIO)
    @Test func unsupportedRawStaysFailedWithoutBlockingOtherFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Фото с пробелами")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in ["camera.cr2", "broken.jpg", "numbers.txt"] {
            try Data("111 222 333 444".utf8).write(to: documents.appendingPathComponent(name))
        }
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("these fixtures need no model") })
        #expect(try indexer.sync([documents]).added == 3)
        var events: [Indexer.Event] = []
        #expect(try indexer.run(onEvent: { events.append($0) }) == ["failed": 2, "done": 1])
        #expect(events.filter { UnsupportedRawImage.matchesFailure($0.note) }.map(\.state) == ["failed"])
        #expect(try store.unsupportedRawCount() == 1)
        #expect(try store.pendingCount() == 0)
        #expect(try keywordCount("333", store: store) == 1)
        #expect(try indexer.sync([documents]).unchanged == 3)
        #expect(try indexer.run().isEmpty)
        #expect(try store.unsupportedRawCount() == 1)
    }
    #endif

    @Test func progressStartsWithTheFilteredQueueBeforeReadingFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Документы с пробелами")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in ["один", "два", "три"] {
            try Data("111 222 333 444".utf8).write(to: documents.appendingPathComponent(name + ".txt"))
        }
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("numeric fixture needs no model") })
        let added = try indexer.sync([documents])
        #expect(added.queued.count == 3)
        var starts: [Int] = []
        var events: [Indexer.Event] = []
        let states = try indexer.run(limit: 1, only: Set(added.queued.prefix(2)), onStart: { total in
            starts.append(total)
            #expect(events.isEmpty)
            #expect((try? store.pendingCount()) == 3)
        }, onEvent: { event in
            #expect(starts == [1])
            events.append(event)
        })
        #expect(states == ["done": 1])
        #expect(starts == [1])
        #expect(events.map(\.done) == [1] && events.map(\.total) == [1])
        #expect(try store.pendingCount() == 2)
        #expect(try indexer.run(only: [], onStart: { starts.append($0) }, onEvent: { _ in
            Issue.record("an empty queue must not process a file")
        }).isEmpty)
        #expect(starts == [1, 0])
    }

    @Test func unicodeFolderLifecycleKeepsOneSearchableRow() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-release-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Документы с пробелами 日本語 🦀")
        let nested = documents.appendingPathComponent("вложенный каталог")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("квитанция 2026.txt")
        // Numeric documents genuinely use keyword search only. Throw if the engine attempts to load any embedder.
        try Data("111 222 333 444".utf8).write(to: original)
        let store = try IndexStore(directory: base.appendingPathComponent("индекс SQLite"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("numeric fixture needs no model") })
        #expect(try indexer.sync([documents]).added == 1)
        #expect(try indexer.run() == ["done": 1])
        let first = try #require(store.files(under: [documents.path]).first)
        #expect(try keywordCount("333", store: store) == 1)
        #expect(try keywordCount("квитанция", store: store) == 1)
        #expect(try indexer.sync([documents, nested]).unchanged == 1)
        #expect(try indexer.run().isEmpty)

        let renamed = nested.appendingPathComponent("новое имя 🦀.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        let moved = try indexer.sync([documents])
        #expect(moved.moved == 1 && moved.added == 0 && moved.removed == 0)
        #expect(try store.files(under: [documents.path]).first?.id == first.id)
        #expect(try keywordCount("333", store: store) == 1)

        try Data("555 666 777 888 999".utf8).write(to: renamed)
        #expect(try indexer.sync([documents]).changed == 1)
        #expect(try indexer.run() == ["done": 1])
        #expect(try keywordCount("333", store: store) == 0)
        #expect(try keywordCount("777", store: store) == 1)
        #expect(try store.files(under: [documents.path]).count == 1)

        try FileManager.default.removeItem(at: renamed)
        #expect(try indexer.sync([documents]).removed == 1)
        #expect(try keywordCount("777", store: store) == 0)
        #expect(try store.files(under: [documents.path]).isEmpty)
    }

    @Test func failedTraversalDoesNotDeleteExistingRows() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("123 456".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("sync does not load a model") })
        #expect(try indexer.sync([root]).added == 1)
        // A file in place of the mount is a deterministic listing error on all OSes, without admin/ACL changes.
        try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("disconnected"))
        try Data().write(to: root)
        let result = try indexer.sync([root])
        #expect(result.removed == 0)
        #expect(!result.crawl.unreadableFolders.isEmpty)
        #expect(try store.files(under: [root.path]).count == 1)
    }

    @Test func supportDirectoryUsesExplicitEnvironment() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("test-home")
        let data = home.appendingPathComponent("Данные пользователя")
        #if os(Windows)
        #expect(AppPaths.applicationSupport(environment: ["LOCALAPPDATA": data.path], home: home)
            == data.appendingPathComponent("DigUp"))
        #expect(AppPaths.applicationSupport(environment: [:], home: home)
            == home.appendingPathComponent("AppData/Local/DigUp"))
        #elseif os(Linux)
        #expect(AppPaths.applicationSupport(environment: ["XDG_DATA_HOME": data.path], home: home)
            == data.appendingPathComponent("digup"))
        #expect(AppPaths.applicationSupport(environment: [:], home: home)
            == home.appendingPathComponent(".local/share/digup"))
        #else
        #expect(AppPaths.applicationSupport(environment: [:], home: home)
            == home.appendingPathComponent("Library/Application Support/DigUp"))
        #endif
    }

    @Test func resumedModelRangeMustMatchPinnedFile() {
        #expect(FileFetcher.acceptsContentRange("bytes 5-9/10", offset: 5, total: 10))
        #expect(FileFetcher.acceptsContentRange("bytes 5-7/10", offset: 5, total: 10))
        #expect(!FileFetcher.acceptsContentRange("bytes 4-9/10", offset: 5, total: 10))
        #expect(!FileFetcher.acceptsContentRange("bytes 5-9/11", offset: 5, total: 10))
        #expect(!FileFetcher.acceptsContentRange("bytes 5-10/10", offset: 5, total: 10))
        #expect(!FileFetcher.acceptsContentRange("bytes 5-4/10", offset: 5, total: 10))
        #expect(!FileFetcher.acceptsContentRange("bytes 5-9/*", offset: 5, total: 10))
        #expect(!FileFetcher.acceptsContentRange("bytes 5-garbage", offset: 5, total: 10))
    }

    #if os(Windows)
    @Test func largeSparseFilesUse64BitMetadataBeforeTypeFiltering() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["ASCII", "Кириллица с пробелами"] {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var paths: [String] = []
            defer {
                // Foundation's stat can itself trap when deleting these fixtures. Use the wide native API.
                for path in paths { _ = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) } }
            }
            let sizes: [Int64] = [(1 << 31) - 1, 1 << 31, 3 << 30, 5 << 30]
            for (i, size) in sizes.enumerated() {
                let path = WindowsPaths.extended(folder.appendingPathComponent("file\(i).jpg", isDirectory: false).path)
                paths.append(path)
                try makeSparseFile(path, size: size)
            }
            // A large unsupported file must not crash a scan before extension filtering runs.
            let ignored = WindowsPaths.extended(folder.appendingPathComponent("ignored.bin", isDirectory: false).path)
            paths.append(ignored)
            try makeSparseFile(ignored, size: 3 << 30)
            let crawl = Crawler.crawl([folder], options: IndexOptions())
            #expect(crawl.unreadableFolders.isEmpty)
            #expect(crawl.candidates.map(\.size).sorted() == sizes)
            #expect(crawl.skipped["other type"] == 1)
            let estimate = Estimator.estimate(crawl.candidates, options: IndexOptions())
            #expect(estimate.files == [.image: 4])
        }
    }

    private func makeSparseFile(_ path: String, size: Int64) throws {
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        try #require(handle != nil && handle != INVALID_HANDLE_VALUE)
        defer { CloseHandle(handle) }
        var returned: DWORD = 0
        // Mark sparse before extending: these multi-GiB logical files allocate no data blocks.
        try #require(DeviceIoControl(handle, 0x0009_00C4, nil, 0, nil, 0, &returned, nil)) // FSCTL_SET_SPARSE
        var end = LARGE_INTEGER()
        end.QuadPart = size
        try #require(SetFilePointerEx(handle, end, nil, DWORD(FILE_BEGIN)))
        try #require(SetEndOfFile(handle))
        var high: DWORD = 0
        let low = path.withCString(encodedAs: UTF16.self) { GetCompressedFileSizeW($0, &high) }
        #expect(high == 0 && low < 65_536)
    }

    @Test func legacyRootCasingKeepsExistingRowAndVectorsWithoutMergingHardLinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-legacy-case-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("MixedCase Документы")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let file = documents.appendingPathComponent("numbers.txt")
        try Data("111 222 333".utf8).write(to: file)
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("numeric fixture needs no model") })
        #expect(try indexer.sync([documents]).added == 1)
        #expect(try indexer.run() == ["done": 1])
        let original = try #require(store.files(under: [documents.path]).first)
        // A known vector checks byte-preserving DB repair independently of embedding inference.
        var vector = [Float](repeating: 0, count: Vectors.dimension)
        vector[0] = 1
        try store.addSegment(file: original.id, kind: .chunk, modality: .text, vector: vector)
        let legacy = documents.path.uppercased() + "/" + file.lastPathComponent
        try store.move(original.id, to: legacy)
        let result = try indexer.sync([documents])
        #expect(result.added == 0 && result.moved == 1 && result.changed == 0)
        #expect(try store.files(under: [documents.path]).map(\.id) == [original.id])
        #expect(try Searcher(store: store).vectorCount == 1)
        #expect(try keywordCount("333", store: store) == 1)

        let linked = documents.appendingPathComponent("separate hard link.txt")
        let created = WindowsPaths.extended(linked.path).withCString(encodedAs: UTF16.self) { target in
            WindowsPaths.extended(file.path).withCString(encodedAs: UTF16.self) { original in
                CreateHardLinkW(target, original, nil)
            }
        }
        try #require(created)
        #expect(try indexer.sync([documents]).added == 1)
        #expect(try store.files(under: [documents.path]).count == 2)

        // A changed legacy file keeps its identity, but correctly queues fresh content and discards stale vectors.
        try store.move(original.id, to: legacy)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("444 555 666 777".utf8))
        try handle.close()
        let changed = try indexer.sync([documents])
        #expect(changed.added == 0 && changed.moved == 1 && changed.queued.contains(original.id))
        #expect(try store.files(under: [documents.path]).contains { $0.id == original.id })
        #expect(try Searcher(store: store).vectorCount == 0)
    }

    @Test func rootCasingDoesNotDuplicateFilesAcrossSyncs() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-case-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Документы MixedCase")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let file = documents.appendingPathComponent("Numbers.txt")
        try Data("123 456".utf8).write(to: file)
        let variant = URL(fileURLWithPath: documents.path.uppercased())
        #expect(FolderSelection.realPath(variant.path) == FolderSelection.realPath(documents.path))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("numeric fixture needs no model") })
        #expect(try indexer.sync([documents, variant]).added == 1)
        #expect(try indexer.run() == ["done": 1])
        #expect(try indexer.sync([variant]).unchanged == 1)
        #expect(try indexer.sync([documents]).unchanged == 1)
        #expect(try store.files(under: [variant.path]).count == 1)
        #expect(try keywordCount("456", store: store) == 1)
        let excluded = documents.appendingPathComponent("SkippedSubfolder")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data("789".utf8).write(to: excluded.appendingPathComponent("secret.txt"))
        var options = IndexOptions()
        options.excludedFolders = [excluded.path.uppercased()]
        // The temporary directory itself may use an 8.3 alias, independently of the tested root casing.
        #expect(Crawler.crawl([variant], options: options).candidates.map(\.path) == [FolderSelection.realPath(file.path)])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: excluded)
        #expect(try indexer.sync([variant]).removed == 1)
    }

    @Test func widePathsSupportDrivesUNCUnicodeAndLongNames() {
        #expect(WindowsPaths.extended("C:/Документы/имя с пробелами.txt") == "\\\\?\\C:\\Документы\\имя с пробелами.txt")
        #expect(WindowsPaths.extended("//server/share/日本語.txt") == "\\\\?\\UNC\\server\\share\\日本語.txt")
        #expect(WindowsPaths.extended("\\\\?\\C:\\already.txt") == "\\\\?\\C:\\already.txt")
        #expect(WindowsPaths.extended("relative/file.txt") == "relative\\file.txt")
        let long = "C:/" + String(repeating: "folder/", count: 50) + "файл.txt"
        #expect(WindowsPaths.extended(long).hasPrefix("\\\\?\\C:\\"))
        #expect(WindowsPaths.extended(long).count > 260)
    }

    @Test func longUnicodeFileIsCrawledThroughWideAPIs() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-long-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: WindowsPaths.extended(base.path)) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var deep = base
        for _ in 0..<8 {
            deep.appendPathComponent("Каталог с пробелами 1234567890")
            // Fixture setup uses the native API, so the test doesn't require a machine-wide LongPathsEnabled policy.
            let created = WindowsPaths.extended(deep.path).withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, nil) }
            try #require(created)
        }
        let file = deep.appendingPathComponent("документ 日本語.txt")
        #expect(file.path.utf16.count > 260)
        try Data("123 456".utf8).write(to: FileAccess.url(file))
        #expect(FileSystem.info(of: file.path)?.isRegular == true)
        #expect(Crawler.crawl([base], options: IndexOptions()).candidates.map(\.path) == [FolderSelection.realPath(file.path)])
        #expect(try DocExtractor.text(of: file) == "123 456")
        // Preview/model output can live under a Unicode username and a long temporary directory too.
        let image = RGBImage(width: 2, height: 2, pixels: [UInt8](repeating: 127, count: 12))
        for png in [true, false] {
            let output = deep.appendingPathComponent("Превью 日本語." + (png ? "png" : "jpg"))
            try image.write(to: output, png: png)
            let decoded = try #require(RGBImage.load(output.path))
            #expect(decoded.width == 2 && decoded.height == 2)
        }
    }
    #endif

    #if !canImport(AVFoundation)
    @Test func mediaToolsAreResolvedBesideExecutableOrFromExplicitFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-resources-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let installed = base.appendingPathComponent("Программа с пробелами")
        let override = base.appendingPathComponent("chosen")
        for directory in [installed, override] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tool = directory.appendingPathComponent(FileSystem.program("ffmpeg"))
            #if os(Windows)
            // Windows checks the PE header, not just the suffix. Copy a real test executable without running it.
            try FileManager.default.copyItem(at: #require(Bundle.main.executableURL), to: tool)
            #else
            _ = FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o700])
            #endif
        }
        let helper = installed.appendingPathComponent(FileSystem.program("digup"))
        #expect(FFmpeg.find("ffmpeg", environment: [:], executable: helper)
            == installed.appendingPathComponent(FileSystem.program("ffmpeg")).path)
        #expect(FFmpeg.find("ffmpeg", environment: ["DIGUP_FFMPEG": override.path], executable: helper)
            == override.appendingPathComponent(FileSystem.program("ffmpeg")).path)
        #if os(Windows)
        #expect(FFmpeg.find("ffprobe", environment: ["PATH": installed.path], executable: nil) == nil)
        #endif
    }
    #endif

    private func keywordCount(_ term: String, store: IndexStore) throws -> Int {
        var count = 0
        try store.db.query("SELECT COUNT(*) FROM fts WHERE fts MATCH ?", [.text("\"\(term)\"")]) {
            count = Int($0.int(0))
        }
        return count
    }
}
