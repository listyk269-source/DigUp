// What every platform shares of the platform layer: the shapes the engine asks for, and where DigUp keeps its files.
// Platform/Apple and Platform/Portable implement the same names.
import Foundation
#if os(Windows)
import WinSDK
#endif

/// A file's own facts, as the crawl records them (`FileSystem.info`).
struct FileInfo {
    let isRegular: Bool   // not a link, device or socket
    let size: Int64
    let mtime: Double     // seconds since 1970, with the fraction the file system keeps
    let inode: UInt64
    let device: UInt64
    /// A cloud placeholder whose contents would be downloaded on read (never read).
    let dataless: Bool
}

#if !canImport(Darwin)
/// Darwin's `autoreleasepool`: elsewhere there's no Objective-C runtime and nothing to drain, so the body just runs.
@discardableResult
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

/// Where DigUp keeps its own files on each OS: the model and the index.
public enum AppPaths {
    /// macOS: ~/Library/Application Support/DigUp. Windows: %LOCALAPPDATA%\DigUp. Linux: $XDG_DATA_HOME/digup, or
    /// ~/.local/share/digup.
    public static var applicationSupport: URL {
        applicationSupport(environment: ProcessInfo.processInfo.environment,
                           home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func applicationSupport(environment: [String: String], home: URL) -> URL {
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/DigUp")
        #elseif os(Windows)
        if let local = environment["LOCALAPPDATA"], !local.isEmpty {
            return URL(fileURLWithPath: local).appendingPathComponent("DigUp")
        }
        return home.appendingPathComponent("AppData/Local/DigUp")
        #else
        if let data = environment["XDG_DATA_HOME"], !data.isEmpty {
            return URL(fileURLWithPath: data).appendingPathComponent("digup")
        }
        return home.appendingPathComponent(".local/share/digup")
        #endif
    }

    /// The default index folder (".noindex" keeps Spotlight out of it on a Mac).
    public static var defaultIndex: URL {
        #if os(macOS)
        return applicationSupport.appendingPathComponent("index.noindex")
        #else
        return applicationSupport.appendingPathComponent("index")
        #endif
    }
}

/// Only the filesystem call sees Windows' extended path spelling; displayed and indexed paths remain ordinary URLs.
public enum FileAccess {
    public static func path(_ path: String) -> String {
        #if os(Windows)
        return WindowsPaths.extended(path)
        #else
        return path
        #endif
    }

    public static func url(_ url: URL) -> URL {
        #if os(Windows)
        return URL(fileURLWithPath: path(url.path))
        #else
        return url
        #endif
    }
}

#if os(Windows)
/// Absolute paths for the wide Win32 APIs, independent of the host's LongPathsEnabled setting. Keep ordinary paths
/// in the database and UI; add the extended prefix only at the native call boundary.
enum WindowsPaths {
    /// Ask the filesystem for its spelling instead of lowercasing: NTFS directories can opt into case sensitivity.
    /// Zero desired access reads the name only. Network/removed folders that cannot be opened keep their spelling.
    static func canonical(_ path: String) -> String {
        let handle = extended(path).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return path }
        defer { CloseHandle(handle) }
        let count = GetFinalPathNameByHandleW(handle, nil, 0, DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS))
        guard count > 0 else { return path }
        var buffer = [WCHAR](repeating: 0, count: Int(count) + 1)
        let written = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS))
        guard written > 0, written < buffer.count else { return path }
        var native = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
        if native.hasPrefix("\\\\?\\UNC\\") { native = "\\\\" + native.dropFirst(8) }
        else if native.hasPrefix("\\\\?\\") { native = String(native.dropFirst(4)) }
        return URL(fileURLWithPath: native).path
    }

    static func extended(_ path: String) -> String {
        let native = path.replacingOccurrences(of: "/", with: "\\")
        if native.hasPrefix("\\\\?\\") || native.hasPrefix("\\\\.\\") { return native }
        if native.hasPrefix("\\\\") { return "\\\\?\\UNC\\" + native.dropFirst(2) }
        let scalars = Array(native.unicodeScalars.prefix(3))
        if scalars.count == 3, scalars[1] == ":", scalars[2] == "\\" {
            return "\\\\?\\" + native
        }
        return native // Relative paths must remain relative; an extended prefix changes their meaning.
    }
}
#endif
