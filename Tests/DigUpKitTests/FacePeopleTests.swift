import Foundation
import Testing
@testable import DigUpKit

@Suite struct FacePeopleTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-people-\(UUID().uuidString)") }
    private func observation(_ score: Float = 1) -> FaceObservation {
        var vector = [Float](repeating: 0, count: 128); vector[0] = score; vector[1] = sqrt(1 - score * score)
        return FaceObservation(bbox: [0.1, 0.2, 0.3, 0.4], landmarks: [0.2, 0.3, 0.3, 0.3, 0.25, 0.4, 0.2, 0.5, 0.3, 0.5],
                               score: 0.98, embedding: vector, loc: nil)
    }
    private func add(_ index: FaceIndexStore, number: Int, modified: Double = 10) throws -> IndexedFace {
        let file = FaceFileVersion(path: "/Фото Лысаченко/Café 🦊 \(number).jpg", kind: "image", size: 100, modified: modified)
        try index.replace(file, model: FaceModels.modelID, config: "fixture", frames: 1, faces: [observation()])
        return try #require(index.observations(path: file.path).first)
    }
    @Test func schemaOneMigrationPreservesExistingFaceRows() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let db = try Database(path: directory.appendingPathComponent(FaceIndexStore.name).path)
            // The shipped schema-one structure, independent of the new migration's CREATE statements.
            try db.execute("""
                CREATE TABLE face_jobs(path TEXT PRIMARY KEY COLLATE BINARY, kind TEXT NOT NULL, size INTEGER NOT NULL,
                  modified REAL NOT NULL, model TEXT NOT NULL, config TEXT NOT NULL, state TEXT NOT NULL, frames INTEGER NOT NULL, completed REAL NOT NULL);
                CREATE TABLE faces(id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL REFERENCES face_jobs(path) ON DELETE CASCADE,
                  bbox BLOB NOT NULL, landmarks BLOB NOT NULL, score REAL NOT NULL, loc REAL, embedding BLOB NOT NULL);
                CREATE TABLE face_meta(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
                INSERT INTO face_meta VALUES('revision',7);
                PRAGMA user_version=1;
                """)
            let face = observation()
            try db.run("INSERT INTO face_jobs VALUES(?,?,?,?,?,?,'done',1,1)", [.text("/Фото/Старый.jpg"), .text("image"), .int(100),
                .double(10), .text(FaceModels.modelID), .text("old")])
            try db.run("INSERT INTO faces VALUES(42,?,?,?,?,?,?)", [.text("/Фото/Старый.jpg"), .blob(try JSONEncoder().encode(face.bbox)),
                .blob(try JSONEncoder().encode(face.landmarks)), .double(face.score), .null, .blob(try JSONEncoder().encode(face.embedding))])
        }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let old = try #require(index.observations().first)
        #expect(old.face.id == 42 && old.face.embedding == observation().embedding && old.file.path == "/Фото/Старый.jpg")
        #expect(try index.revision() == 7 && people.revision() == 0)
        #expect(try people.people().isEmpty)
        var version: Int64 = 0; try index.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(IndexStore.mainFile).path))
    }
    @Test func bulkBeyondOnePageExclusionsConflictsAndUndoAreAtomic() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let faces = try (0..<52).map { try add(index, number: $0) }
        let a = try people.save(name: "Человек А").0, b = try people.save(name: "Человек Б").0
        _ = try people.label(person: b.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) { consume in try consume(faces[0]) }
        let faceRevision = try index.revision()
        let changed = try people.label(person: a.id, action: "assign", expectedIndex: faceRevision,
            exclusions: [faces[1].face.id, faces[2].face.id], accepts: { $0.path != faces[3].file.path }) { consume in
                for face in faces { try consume(face) }
            }
        #expect(changed.changed == 48 && changed.conflicts == 1 && changed.excluded == 2 && changed.stale == 1)
        #expect(try people.annotations(person: a.id).count == 48)
        #expect(try index.revision() == faceRevision)
        let undo = try people.undo(#require(changed.operationID))
        #expect(undo.changed == 48)
        #expect(try people.annotations(person: a.id).isEmpty)
        #expect(try people.annotations(person: b.id).count == 1)
        #expect(throws: (any Error).self) { try people.undo(#require(changed.operationID)) }
    }
    @Test func rejectionAndUndoNeverAutoAssignSimilarNewFiles() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let face = try add(index, number: 1), person = try people.save(name: "Наблюдатель").0
        _ = try people.label(person: person.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(face) }
        let rejected = try people.label(person: person.id, action: "reject", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(face) }
        #expect(try people.annotations(person: person.id).first?.state == "rejected")
        _ = try add(index, number: 2) // Exact same real-vector shape is still only an unassigned candidate.
        #expect(try people.annotations().count == 1)
        _ = try people.undo(#require(rejected.operationID))
        #expect(try people.annotations(person: person.id).first?.state == "assigned")
        let removed = try people.label(person: person.id, action: "remove", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(face) }
        #expect(try people.annotations().isEmpty)
        _ = try people.undo(#require(removed.operationID))
        #expect(try people.annotations().first?.state == "assigned")
    }
    @Test func exactAnchorsSurviveReindexAndStaleSnapshotsRemainRecoverable() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let original = try add(index, number: 1), person = try people.save(name: "Лицо café").0
        _ = try people.label(person: person.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(original) }
        let replaced = try add(index, number: 1)
        #expect(replaced.face.id != original.face.id)
        #expect(FacePersonSnapshot(replaced).anchor == FacePersonSnapshot(original).anchor)
        let decomposed = IndexedFace(face: original.face,
            file: FaceFileVersion(path: original.file.path.replacingOccurrences(of: "Café", with: "Cafe\u{301}"),
                                  kind: original.file.kind, size: original.file.size, modified: original.file.modified), model: original.model)
        #expect(FacePersonSnapshot(decomposed).anchor != FacePersonSnapshot(original).anchor)
        #expect(try people.annotations(anchor: FacePersonSnapshot(replaced).anchor).first?.personID == person.id)
        let modified = try add(index, number: 1, modified: 11)
        #expect(FacePersonSnapshot(modified).anchor != FacePersonSnapshot(original).anchor)
        #expect(try people.annotations(anchor: FacePersonSnapshot(modified).anchor).isEmpty)
        try index.removeDeleted(retainedPaths: [])
        #expect(try index.observations().isEmpty && people.annotations().count == 1)
        let annotation = try #require(people.annotations().first)
        #expect(annotation.snapshot.file.modified == 10)
        let removed = try people.label(person: person.id, action: "remove", expectedIndex: index.revision(), removeAnchors: [annotation.anchor],
            accepts: { _ in false }, acceptsStaleAnchor: { _ in true }) { _ in }
        #expect(removed.changed == 1)
        #expect(try people.annotations().isEmpty)
    }
    @Test func unicodeNamesRenameAndLatestOnlyUndoGuard() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let people = FacePeopleStore(index: try FaceIndexStore(directory: directory))
        let a = try people.save(name: "  СЁМЁН Café 🦊  ").0
        #expect(a.name == "СЁМЁН Café 🦊")
        #expect(FacePeopleStore.matches(name: a.name, query: "семен CAFÉ"))
        #expect(FacePeopleStore.matches(name: a.name, query: "   "))
        let rename = try people.save(name: "Наблюдатель", id: a.id).1
        _ = try people.undo(#require(rename.operationID))
        #expect(try people.person(a.id).name == a.name)
        let rename2 = try people.save(name: "Другое имя", id: a.id).1
        _ = try people.save(name: "Новый человек")
        #expect(throws: (any Error).self) { try people.undo(#require(rename2.operationID)) }
        #expect(try people.person(a.id).name == "Другое имя")
        for invalid in ["   ", "Имя\nВторая строка", String(repeating: "Я", count: 121)] {
            #expect(throws: (any Error).self) { try people.save(name: invalid) }
        }
    }
    @Test func revisionAndScopeFailuresRollbackWholeBulkAndKeepPreviousUndo() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let face = try add(index, number: 1), (person, created) = try people.save(name: "Человек")
        let oldIndex = try index.revision(); _ = try add(index, number: 2)
        #expect(throws: (any Error).self) {
            try people.label(person: person.id, action: "assign", expectedIndex: oldIndex, accepts: { _ in true }) { try $0(face) }
        }
        var calls = 0
        #expect(throws: (any Error).self) {
            try people.label(person: person.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }, checkScope: {
                calls += 1
                if calls == 2 { throw FacePeopleStore.Failure("Folder selection changed") }
            }) { try $0(face) }
        }
        #expect(try people.annotations().isEmpty && people.undoOperationID() == created.operationID)
        #expect(throws: (any Error).self) { try people.save(name: "Changed", id: person.id, expected: 0) }
        let invalid = IndexedFace(face: observation(), file: FaceFileVersion(path: "/invalid.jpg", kind: "image", size: 1, modified: .nan), model: FaceModels.modelID)
        #expect(throws: (any Error).self) {
            try people.label(person: person.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(invalid) }
        }
        #expect(try people.annotations().isEmpty)
    }
    @Test func undoOutsideSelectedScopeFailsWithoutLosingCurrentAssignments() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let first = try add(index, number: 1), second = try add(index, number: 2), person = try people.save(name: "Человек").0
        let assigned = try people.label(person: person.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) {
            try $0(first); try $0(second)
        }
        #expect(throws: (any Error).self) {
            try people.undo(#require(assigned.operationID), accepts: { $0.file.path == first.file.path })
        }
        #expect(try people.annotations().count == 2)
        _ = try people.undo(#require(assigned.operationID))
        #expect(try people.annotations().isEmpty)
    }
    @Test func proposalReferencesAreBoundedDeterministicAndNeverCreateLabels() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = FacePeopleStore(index: try FaceIndexStore(directory: directory))
        let values = (1...120).map { observation(Float($0) / 121).embedding }
        var forward = FacePeopleReferences(), reverse = FacePeopleReferences()
        for vector in values { forward.add(vector) }
        for vector in values.reversed() { reverse.add(vector) }
        #expect(forward.count == 64 && reverse.count == 64 && forward.sampled)
        #expect(forward.vectors == reverse.vectors && forward.sourceCount == 120)
        for _ in 0..<1000 { forward.add(values[0]) }
        #expect(forward.count == 64 && forward.vectors == reverse.vectors)
        #expect(forward.score(values[40]) == reverse.score(values[40]))
        #expect(try store.people().isEmpty && store.annotations().isEmpty)
        var invalid = FacePeopleReferences(); invalid.add([.nan])
        #expect(invalid.count == 0 && invalid.sourceCount == 0)
    }
    @Test func bulkAssignmentPreservesRejectionsAndExplicitAssignmentCanUndoToRejected() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FaceIndexStore(directory: directory), people = FacePeopleStore(index: index)
        let face = try add(index, number: 1), person = try people.save(name: "Человек").0
        _ = try people.label(person: person.id, action: "reject", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(face) }
        let all = try people.label(person: person.id, action: "assign", expectedIndex: index.revision(), respectRejections: true,
            accepts: { _ in true }) { try $0(face) }
        #expect(all.changed == 0 && all.excluded == 1)
        let alsoExcluded = try people.label(person: person.id, action: "assign", expectedIndex: index.revision(),
            exclusions: [face.face.id], respectRejections: true, accepts: { _ in true }) { try $0(face) }
        #expect(alsoExcluded.changed == 0 && alsoExcluded.excluded == 1)
        #expect(try people.annotations().first?.state == "rejected")
        let selected = try people.label(person: person.id, action: "assign", expectedIndex: index.revision(), accepts: { _ in true }) { try $0(face) }
        #expect(selected.changed == 1)
        #expect(try people.annotations().first?.state == "assigned")
        _ = try people.undo(#require(selected.operationID))
        #expect(try people.annotations().first?.state == "rejected")
    }
}
