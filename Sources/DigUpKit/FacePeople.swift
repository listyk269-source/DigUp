import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct FacePerson: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
}

/// A manual decision survives replacement of numeric face IDs. Exact coordinates and file/model versions are
/// intentional: a changed file or a different detector observation never silently inherits a person's name.
public struct FacePersonSnapshot: Codable, Sendable, Equatable {
    public let file: FaceFileVersion
    public let model: String
    public let bbox: [Double]
    public let landmarks: [Double]
    public let score: Double
    public let loc: Double?
    public init(_ observation: IndexedFace) {
        file = observation.file; model = observation.model; bbox = observation.face.bbox
        landmarks = observation.face.landmarks; score = observation.face.score; loc = observation.face.loc
    }
    public var anchor: String {
        // Quality and landmarks can change without changing which exact observation is shown. Neither a name nor
        // an embedding is part of this key; canonically equivalent Unicode paths must still preserve their bytes.
        struct Identity: Encodable {
            let file: FaceFileVersion
            let model: String
            let bbox: [Double]
            let loc: Double?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Identity(file: file, model: model, bbox: bbox, loc: loc)) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct FacePersonAnnotation: Sendable {
    public let anchor: String
    public let personID: String
    public let state: String
    public let snapshot: FacePersonSnapshot
}

public struct FacePeopleChange: Sendable {
    public let operationID: String?
    public let revision: Int64
    public let changed: Int
    public let conflicts: Int
    public let stale: Int
    public let excluded: Int
}

/// A deterministic bottom-hash sample of actual confirmed descriptors. Both stored vectors and dedup state stay
/// bounded by the limit; repeated discarded descriptors cannot re-enter because the largest retained hash only
/// decreases. This limits proposal work without deleting any manual assignment or inventing an average person.
public struct FacePeopleReferences: Sendable {
    public static let limit = 64
    private var selected: [Data: [Float]] = [:]
    public private(set) var sourceCount = 0
    public private(set) var sampled = false
    public init() {}
    public var count: Int { selected.count }
    public var vectors: [[Float]] { selected.keys.sorted { $0.lexicographicallyPrecedes($1) }.compactMap { selected[$0] } }
    public mutating func add(_ vector: [Float]) {
        guard vector.count == 128, vector.allSatisfy(\.isFinite), abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.02 else { return }
        sourceCount += 1
        var bytes = Data(capacity: 512)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        let hash = Data(SHA256.hash(data: bytes))
        guard selected[hash] == nil else { return }
        if selected.count < Self.limit { selected[hash] = vector; return }
        sampled = true
        guard let greatest = selected.keys.max(by: { $0.lexicographicallyPrecedes($1) }), hash.lexicographicallyPrecedes(greatest) else { return }
        selected.removeValue(forKey: greatest); selected[hash] = vector
    }
    public func score(_ vector: [Float]) -> Double? {
        selected.values.compactMap { FaceIndexStore.cosine($0, vector) }.max()
    }
}

/// Manual decisions have their own revision and undo log. Inference replaces only face_jobs/faces, never these
/// tables. One confirmed person per anchor; rejected candidates remain rejected until an explicit user decision.
public final class FacePeopleStore {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
    public let index: FaceIndexStore
    private var db: Database { index.db }
    public init(index: FaceIndexStore) { self.index = index }
    static func migrate(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS people(id TEXT PRIMARY KEY, name TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS face_person_annotations(
                anchor TEXT NOT NULL, person TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                state TEXT NOT NULL CHECK(state IN ('assigned','rejected')), snapshot BLOB NOT NULL, created REAL NOT NULL,
                PRIMARY KEY(anchor,person));
            CREATE UNIQUE INDEX IF NOT EXISTS face_one_person ON face_person_annotations(anchor) WHERE state = 'assigned';
            CREATE INDEX IF NOT EXISTS face_person_state ON face_person_annotations(person,state);
            CREATE TABLE IF NOT EXISTS people_operation(
                id TEXT PRIMARY KEY, revision INTEGER NOT NULL, kind TEXT NOT NULL,
                person TEXT, previous_name TEXT, created_person TEXT);
            CREATE TABLE IF NOT EXISTS people_undo_annotations(
                operation TEXT NOT NULL, anchor TEXT NOT NULL, person TEXT NOT NULL,
                previous_state TEXT, previous_snapshot BLOB, previous_created REAL, PRIMARY KEY(operation,anchor,person));
            INSERT OR IGNORE INTO face_meta(key,value) VALUES('people_revision',0);
            """)
    }
    public func revision() throws -> Int64 {
        var result: Int64 = 0
        try db.query("SELECT value FROM face_meta WHERE key = 'people_revision'") { result = $0.int(0) }
        return result
    }
    public func people() throws -> [FacePerson] {
        var result: [FacePerson] = []
        try db.query("SELECT id,name FROM people ORDER BY name COLLATE NOCASE,id") { row in
            if let id = row.text(0), let name = row.text(1) { result.append(FacePerson(id: id, name: name)) }
        }
        return result.sorted {
            let a = Self.fold($0.name), b = Self.fold($1.name)
            return a == b ? $0.id < $1.id : a < b
        }
    }
    public static func matches(name: String, query: String) -> Bool {
        let query = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return query.isEmpty || fold(name).contains(query)
    }
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public func person(_ id: String) throws -> FacePerson {
        guard let found = try people().first(where: { $0.id == id }) else { throw Failure("This person no longer exists. Refresh People.") }
        return found
    }
    public func undoOperationID() throws -> String? {
        var id: String?
        let revision = try revision()
        try db.query("SELECT id FROM people_operation WHERE revision = ?", [.int(revision)]) { id = $0.text(0) }
        return id
    }
    public func annotations(person: String? = nil, anchor: String? = nil) throws -> [FacePersonAnnotation] {
        var result: [FacePersonAnnotation] = []
        try forEachAnnotation(person: person, anchor: anchor) { result.append($0) }
        return result
    }
    public func forEachAnnotation(person: String? = nil, anchor: String? = nil,
                                  _ consume: (FacePersonAnnotation) throws -> Void) throws {
        var clauses: [String] = [], values: [SQLValue] = []
        if let person { clauses.append("person = ?"); values.append(.text(person)) }
        if let anchor { clauses.append("anchor = ?"); values.append(.text(anchor)) }
        try db.query("SELECT anchor,person,state,snapshot FROM face_person_annotations" +
                     (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY anchor,person", values) { row in
            if let anchor = row.text(0), let person = row.text(1), let state = row.text(2), let data = row.blob(3),
               let snapshot = try? JSONDecoder().decode(FacePersonSnapshot.self, from: data) {
                try consume(FacePersonAnnotation(anchor: anchor, personID: person, state: state, snapshot: snapshot))
            }
        }
    }

    private func check(_ expected: Int64?) throws {
        if let expected, try revision() != expected { throw Failure("People changed. Refresh before applying this action.") }
    }
    private func begin(_ id: String, kind: String, person: String? = nil, previousName: String? = nil, created: String? = nil) throws {
        try db.execute("DELETE FROM people_undo_annotations; DELETE FROM people_operation")
        try db.run("INSERT INTO people_operation VALUES(?,?,?,?,?,?)", [.text(id), .int(try revision() + 1), .text(kind),
            person.map(SQLValue.text) ?? .null, previousName.map(SQLValue.text) ?? .null, created.map(SQLValue.text) ?? .null])
    }
    private func increment() throws { try db.execute("UPDATE face_meta SET value = value + 1 WHERE key = 'people_revision'") }
    public func save(name: String, id: String? = nil, expected: Int64? = nil) throws -> (FacePerson, FacePeopleChange) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, name.utf8.count <= 1024,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("Enter a person name between 1 and 120 characters without control characters.")
        }
        return try db.transaction {
            try check(expected)
            let operation = UUID().uuidString
            if let id {
                let old = try person(id)
                if old.name.utf8.elementsEqual(name.utf8) {
                    return (old, FacePeopleChange(operationID: nil, revision: try revision(), changed: 0, conflicts: 0, stale: 0, excluded: 0))
                }
                try begin(operation, kind: "rename", person: id, previousName: old.name)
                try db.run("UPDATE people SET name = ? WHERE id = ?", [.text(name), .text(id)])
                try increment()
                return (FacePerson(id: id, name: name), FacePeopleChange(operationID: operation, revision: try revision(), changed: 1, conflicts: 0, stale: 0, excluded: 0))
            }
            let id = UUID().uuidString
            try begin(operation, kind: "create", created: id)
            try db.run("INSERT INTO people VALUES(?,?,?)", [.text(id), .text(name), .double(Date().timeIntervalSince1970)])
            try increment()
            return (FacePerson(id: id, name: name), FacePeopleChange(operationID: operation, revision: try revision(), changed: 1, conflicts: 0, stale: 0, excluded: 0))
        }
    }

    /// Enumeration runs inside one write transaction: a bulk action covers every matching observation, including
    /// unloaded pages, and cannot race a face publication. Undo is streamed to SQLite rather than held in memory.
    public func label(person: String, action: String, expectedIndex: Int64, expectedPeople: Int64? = nil,
                      exclusions: Set<Int64> = [], removeAnchors: [String] = [],
                      respectRejections: Bool = false,
                      accepts: @escaping (FaceFileVersion) -> Bool, acceptsStaleAnchor: ((FaceFileVersion) -> Bool)? = nil,
                      checkScope: () throws -> Void = {},
                      enumerate: (_ consume: (IndexedFace) throws -> Void) throws -> Void) throws -> FacePeopleChange {
        guard ["assign", "remove", "reject"].contains(action), removeAnchors.isEmpty || action == "remove" else {
            throw Failure("Choose assign, remove or reject.")
        }
        return try db.transaction {
            try check(expectedPeople); try checkScope()
            guard try index.revision() == expectedIndex else { throw Failure("Face index changed. Run the face search again.") }
            _ = try self.person(person)
            let operation = UUID().uuidString
            var changed = 0, conflicts = 0, stale = 0, excluded = 0, seen = Set<String>()
            func apply(anchor: String, snapshot: FacePersonSnapshot, state: String?) throws {
                guard seen.insert(anchor).inserted else { return }
                let previous = try annotations(person: person, anchor: anchor).first
                if action == "assign", respectRejections, previous?.state == "rejected" { excluded += 1; return }
                if action == "assign", try annotations(anchor: anchor).contains(where: { $0.state == "assigned" && $0.personID != person }) {
                    conflicts += 1; return
                }
                if previous?.state == state || (previous == nil && state == nil) { return }
                if changed == 0 { try begin(operation, kind: "labels", person: person) }
                // Snapshot the exact previous row before replacing it, including a prior rejection.
                var previousCreated: Double?
                try db.query("SELECT created FROM face_person_annotations WHERE anchor = ? AND person = ?", [.text(anchor), .text(person)]) { previousCreated = $0.double(0) }
                try db.run("INSERT INTO people_undo_annotations VALUES(?,?,?,?,?,?)", [.text(operation), .text(anchor), .text(person),
                    previous.map { .text($0.state) } ?? .null,
                    try previous.map { .blob(try JSONEncoder().encode($0.snapshot)) } ?? .null,
                    previousCreated.map(SQLValue.double) ?? .null])
                try db.run("DELETE FROM face_person_annotations WHERE anchor = ? AND person = ?", [.text(anchor), .text(person)])
                if let state {
                    try db.run("INSERT INTO face_person_annotations VALUES(?,?,?,?,?)", [.text(anchor), .text(person), .text(state),
                        .blob(try JSONEncoder().encode(snapshot)), .double(Date().timeIntervalSince1970)])
                }
                changed += 1
            }
            try enumerate { observation in
                if exclusions.contains(observation.face.id) { excluded += 1; return }
                guard accepts(observation.file) else { stale += 1; return }
                let snapshot = FacePersonSnapshot(observation)
                guard !snapshot.anchor.isEmpty else { throw Failure("This face has invalid version metadata.") }
                try apply(anchor: snapshot.anchor, snapshot: snapshot, state: action == "remove" ? nil : action == "assign" ? "assigned" : "rejected")
            }
            for anchor in removeAnchors {
                guard let annotation = try annotations(person: person, anchor: anchor).first else { continue }
                guard acceptsStaleAnchor?(annotation.snapshot.file) ?? accepts(annotation.snapshot.file) else { stale += 1; continue }
                try apply(anchor: anchor, snapshot: annotation.snapshot, state: nil)
            }
            try checkScope()
            if changed > 0 { try increment() }
            return FacePeopleChange(operationID: changed > 0 ? operation : nil, revision: try revision(), changed: changed,
                                    conflicts: conflicts, stale: stale, excluded: excluded)
        }
    }

    /// Reject every current observation of this exact file for one person, including unloaded video frames.
    /// The underlying descriptors and other people's assignments are unchanged; the existing undo log covers it.
    public func excludeFile(person: String, file: FaceFileVersion, expectedIndex: Int64, expectedPeople: Int64? = nil,
                            accepts: @escaping (FaceFileVersion) -> Bool,
                            checkScope: () throws -> Void = {}) throws -> FacePeopleChange {
        try label(person: person, action: "reject", expectedIndex: expectedIndex, expectedPeople: expectedPeople,
                  accepts: accepts, checkScope: checkScope) { [self] consume in
            guard accepts(file) else { throw Failure("This file changed or is outside the selected folders. Refresh People.") }
            try index.forEach(path: file.path, model: FaceModels.modelID) { observation in
                guard observation.file == file else { throw Failure("This file changed. Refresh People before excluding it.") }
                try consume(observation)
            }
        }
    }

    public func undo(_ operation: String, expectedPeople: Int64? = nil,
                     accepts: (FacePersonSnapshot) -> Bool = { _ in true }, checkScope: () throws -> Void = {}) throws -> FacePeopleChange {
        try db.transaction {
            try check(expectedPeople)
            try checkScope()
            var kind: String?, person: String?, previousName: String?, created: String?
            try db.query("SELECT kind,person,previous_name,created_person FROM people_operation WHERE id = ? AND revision = ?",
                         [.text(operation), .int(try revision())]) { row in
                kind = row.text(0); person = row.text(1); previousName = row.text(2); created = row.text(3)
            }
            guard let kind else { throw Failure("Only the latest People action can be undone. Refresh People.") }
            var changed = 0
            if kind == "rename", let person, let previousName {
                try db.run("UPDATE people SET name = ? WHERE id = ?", [.text(previousName), .text(person)]); changed = 1
            } else if kind == "create", let created {
                try db.run("DELETE FROM people WHERE id = ?", [.text(created)]); changed = 1
            } else if kind == "labels" {
                try db.query("SELECT anchor,person,previous_state,previous_snapshot,previous_created FROM people_undo_annotations WHERE operation = ?", [.text(operation)]) { row in
                    guard let anchor = row.text(0), let person = row.text(1) else { return }
                    var snapshot = row.blob(3).flatMap { try? JSONDecoder().decode(FacePersonSnapshot.self, from: $0) }
                    if snapshot == nil { snapshot = try annotations(person: person, anchor: anchor).first?.snapshot }
                    guard let snapshot, accepts(snapshot) else { throw Failure("The action includes faces outside the selected folders. Restore the folder selection before undoing it.") }
                    try db.run("DELETE FROM face_person_annotations WHERE anchor = ? AND person = ?", [.text(anchor), .text(person)])
                    if let state = row.text(2), let snapshot = row.blob(3) {
                        try db.run("INSERT INTO face_person_annotations VALUES(?,?,?,?,?)", [.text(anchor), .text(person), .text(state), .blob(snapshot), .double(row.double(4))])
                    }
                    changed += 1
                }
            }
            try checkScope()
            try db.execute("DELETE FROM people_undo_annotations; DELETE FROM people_operation")
            try increment()
            return FacePeopleChange(operationID: nil, revision: try revision(), changed: changed, conflicts: 0, stale: 0, excluded: 0)
        }
    }
}
