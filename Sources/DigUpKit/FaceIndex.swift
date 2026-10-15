import Foundation

/// A face index is deliberately separate from EmbeddingGemma's 768-dimensional segment matrix.
/// Every observation belongs to an exact file version and model/preprocessing version.
public struct FaceFileVersion: Sendable, Equatable {
    public let path: String
    public let kind: String
    public let size: Int64
    public let modified: Double
    public init(path: String, kind: String, size: Int64, modified: Double) {
        self.path = path; self.kind = kind; self.size = size; self.modified = modified
    }
}

public struct FaceObservation: Sendable, Codable {
    public var id: Int64 = 0
    public let bbox: [Double]
    public let landmarks: [Double]
    public let score: Double
    public let embedding: [Float]
    public let loc: Double?
    public init(bbox: [Double], landmarks: [Double], score: Double, embedding: [Float], loc: Double?) {
        self.bbox = bbox; self.landmarks = landmarks; self.score = score; self.embedding = embedding; self.loc = loc
    }
    public var isValid: Bool {
        bbox.count == 4 && bbox.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
            && bbox[2] > 0 && bbox[3] > 0 && bbox[0] + bbox[2] <= 1.00001 && bbox[1] + bbox[3] <= 1.00001
            && landmarks.count == 10 && landmarks.allSatisfy { $0.isFinite }
            && score.isFinite && (0...1).contains(score)
            && embedding.count == 128 && embedding.allSatisfy(\.isFinite)
            && abs(embedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.02
            && (loc == nil || (loc!.isFinite && loc! >= 0))
    }
}

public struct IndexedFace: Sendable {
    public let face: FaceObservation
    public let file: FaceFileVersion
    public let model: String
}

/// One connection per thread, as with Database. Atomic replacement means a cancelled file is retried whole.
public final class FaceIndexStore {
    public static let name = "face-index.sqlite"
    public let db: Database
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent(Self.name).path)
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version <= 1 else { throw Database.Failure(message: "The face index needs a newer DigUp.") }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS face_jobs(
                path TEXT PRIMARY KEY COLLATE BINARY, kind TEXT NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL,
                model TEXT NOT NULL, config TEXT NOT NULL, state TEXT NOT NULL, frames INTEGER NOT NULL,
                completed REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS faces(
                id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL REFERENCES face_jobs(path) ON DELETE CASCADE,
                bbox BLOB NOT NULL, landmarks BLOB NOT NULL, score REAL NOT NULL, loc REAL, embedding BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS faces_path ON faces(path);
            CREATE TABLE IF NOT EXISTS face_meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            INSERT OR IGNORE INTO face_meta(key, value) VALUES('revision', 0);
            PRAGMA user_version = 1;
            """)
    }

    public func completed(_ file: FaceFileVersion, model: String, config: String) throws -> Bool {
        var found = false
        try db.query("SELECT 1 FROM face_jobs WHERE path = ? AND kind = ? AND size = ? AND modified = ? AND model = ? AND config = ? AND state = 'done'",
                     [.text(file.path), .text(file.kind), .int(file.size), .double(file.modified), .text(model), .text(config)]) { _ in found = true }
        return found
    }

    public func replace(_ file: FaceFileVersion, model: String, config: String, frames: Int,
                        faces: [FaceObservation], failed: Bool = false) throws {
        guard faces.allSatisfy(\.isValid), !model.isEmpty, frames >= 0, !failed || faces.isEmpty else {
            throw Database.Failure(message: "Invalid face observations; the previous index was preserved.")
        }
        try db.transaction {
            try db.run("DELETE FROM face_jobs WHERE path = ?", [.text(file.path)])
            try db.run("INSERT INTO face_jobs VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       [.text(file.path), .text(file.kind), .int(file.size), .double(file.modified), .text(model),
                        .text(config), .text(failed ? "failed" : "done"), .int(Int64(frames)), .double(Date().timeIntervalSince1970)])
            for face in faces {
                try db.run("INSERT INTO faces(path, bbox, landmarks, score, loc, embedding) VALUES(?, ?, ?, ?, ?, ?)",
                           [.text(file.path), .blob(try JSONEncoder().encode(face.bbox)), .blob(try JSONEncoder().encode(face.landmarks)),
                            .double(face.score), face.loc.map(SQLValue.double) ?? .null, .blob(try JSONEncoder().encode(face.embedding))])
            }
            try db.execute("UPDATE face_meta SET value = value + 1 WHERE key = 'revision'")
        }
    }

    /// Stream a potentially long video from private scratch storage; memory stays bounded by one observation.
    /// The old job survives cancellation, invalid input and disk errors because publication is one transaction.
    public func replaceStaged(_ file: FaceFileVersion, model: String, config: String, frames: Int,
                              staged: URL, cancellation: FaceCancellation) throws {
        let handle = try FileHandle(forReadingFrom: staged)
        defer { try? handle.close() }
        try cancellation.check()
        try db.transaction {
            try db.run("DELETE FROM face_jobs WHERE path = ?", [.text(file.path)])
            try db.run("INSERT INTO face_jobs VALUES(?, ?, ?, ?, ?, ?, 'done', ?, ?)",
                       [.text(file.path), .text(file.kind), .int(file.size), .double(file.modified), .text(model), .text(config),
                        .int(Int64(frames)), .double(Date().timeIntervalSince1970)])
            var pending = Data()
            while true {
                try cancellation.check()
                let chunk = try handle.read(upToCount: 65536) ?? Data()
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    try cancellation.check()
                    let face = try JSONDecoder().decode(FaceObservation.self, from: pending[..<end])
                    guard face.isValid else { throw Database.Failure(message: "Invalid staged face observation.") }
                    try db.run("INSERT INTO faces(path, bbox, landmarks, score, loc, embedding) VALUES(?, ?, ?, ?, ?, ?)",
                               [.text(file.path), .blob(try JSONEncoder().encode(face.bbox)), .blob(try JSONEncoder().encode(face.landmarks)),
                                .double(face.score), face.loc.map(SQLValue.double) ?? .null, .blob(try JSONEncoder().encode(face.embedding))])
                    pending.removeSubrange(...end)
                }
                guard pending.count <= 32768 else { throw Database.Failure(message: "Invalid staged face observation size.") }
                if chunk.isEmpty {
                    guard pending.isEmpty else { throw Database.Failure(message: "The staged face observations are truncated.") }
                    break
                }
            }
            try cancellation.check()
            try db.execute("UPDATE face_meta SET value = value + 1 WHERE key = 'revision'")
        }
    }

    public func revision() throws -> Int64 {
        var revision: Int64 = 0
        try db.query("SELECT value FROM face_meta WHERE key = 'revision'") { revision = $0.int(0) }
        return revision
    }

    public func count(path: String, model: String) throws -> Int {
        var count = 0
        try db.query("SELECT count(*) FROM faces f JOIN face_jobs j ON j.path = f.path WHERE j.state = 'done' AND j.path = ? AND j.model = ?",
                     [.text(path), .text(model)]) { count = Int($0.int(0)) }
        return count
    }

    public func observations(path: String? = nil, model: String? = nil, id: Int64? = nil,
                             offset: Int = 0, limit: Int? = nil) throws -> [IndexedFace] {
        var result: [IndexedFace] = []
        try forEach(path: path, model: model, id: id, offset: offset, limit: limit) { result.append($0) }
        return result
    }

    /// Streaming vectors keeps a long-video search from materializing every 128-component embedding at once.
    public func forEach(path: String? = nil, model: String? = nil, id: Int64? = nil,
                        offset: Int = 0, limit: Int? = nil, _ consume: (IndexedFace) throws -> Void) throws {
        var clauses = ["j.state = 'done'"], values: [SQLValue] = []
        if let path { clauses.append("j.path = ?"); values.append(.text(path)) }
        if let model { clauses.append("j.model = ?"); values.append(.text(model)) }
        if let id { clauses.append("f.id = ?"); values.append(.int(id)) }
        let bounds = limit.map { _ in " LIMIT ? OFFSET ?" } ?? ""
        if let limit { values += [.int(Int64(max(0, limit))), .int(Int64(max(0, offset)))] }
        try db.query("""
            SELECT f.id, f.bbox, f.landmarks, f.score, f.loc, f.embedding, j.path, j.kind, j.size, j.modified, j.model
            FROM faces f JOIN face_jobs j ON j.path = f.path WHERE \(clauses.joined(separator: " AND ")) ORDER BY f.id\(bounds)
            """, values) { row in
            guard let bbox = row.blob(1), let landmarks = row.blob(2), let embedding = row.blob(5), let path = row.text(6),
                  let b = try? JSONDecoder().decode([Double].self, from: bbox),
                  let l = try? JSONDecoder().decode([Double].self, from: landmarks),
                  let e = try? JSONDecoder().decode([Float].self, from: embedding) else { return }
            var observation = FaceObservation(bbox: b, landmarks: l, score: row.double(3), embedding: e,
                                              loc: row.isNull(4) ? nil : row.double(4))
            guard observation.isValid else { return }
            observation.id = row.int(0)
            try consume(IndexedFace(face: observation,
                                    file: FaceFileVersion(path: path, kind: row.text(7) ?? "image", size: row.int(8), modified: row.double(9)),
                                    model: row.text(10) ?? ""))
        }
    }

    /// Reconcile against retained semantic records, not disk reachability: unplugging a drive keeps its index.
    public func removeDeleted(retainedPaths: Set<Data>) throws {
        var removed: [String] = []
        try db.query("SELECT path FROM face_jobs") { row in
            if let path = row.text(0), !retainedPaths.contains(Data(path.utf8)) { removed.append(path) }
        }
        try db.transaction {
            for path in removed { try db.run("DELETE FROM face_jobs WHERE path = ?", [.text(path)]) }
            if !removed.isEmpty { try db.execute("UPDATE face_meta SET value = value + 1 WHERE key = 'revision'") }
        }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == 128, b.count == 128, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
        let value = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return value.isFinite ? min(1, max(-1, value)) : nil
    }
}
