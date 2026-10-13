import Foundation
import Testing

@testable import DigUpKit

@Suite struct EstimateCountsTests {
    @Test func countsOnlyNeedsNeitherHeadersNorModels() {
        // These files do not exist: folder selection only needs the crawler's candidate metadata. Every kind must
        // count, while PDF pages, media durations and code size estimates remain explicitly unmeasured.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-counts-\(UUID().uuidString)")
        let candidates = FileKind.allCases.map { kind in
            Candidate(
                path: root.appendingPathComponent("Каталог с пробелами/\(kind.rawValue)").path,
                kind: kind, size: 1 << 20, mtime: 1, inode: 0, device: 0)
        }
        let groups = Estimator.estimates(bySubfolder: candidates, of: root.path, options: IndexOptions(), countsOnly: true)
        #expect(groups.count == 1)
        let count = groups.values.reduce(Estimate(), +)
        #expect(count.files == Dictionary(uniqueKeysWithValues: FileKind.allCases.map { ($0, 1) }))
        #expect(count.seconds == 0 && count.laterSeconds == 0 && count.bytes == 0)
        #expect(count.pdfPages == 0 && count.pdfPagesTotal == 0 && count.docChunks == 0)
        #expect(count.audioSeconds == 0 && count.videoSeconds == 0 && count.codeStretches == 0 && count.longFiles == 0)
    }

    @Test func countsOnlyKeepsRootAndImmediateSubfolderGroups() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-counts-\(UUID().uuidString)")
        let candidates = ["root.txt", "Кириллица/one.txt", "Кириллица/deeper/two.txt", "Second/three.txt"].map {
            Candidate(path: root.appendingPathComponent($0).path, kind: .doc, size: 100, mtime: 1, inode: 0, device: 0)
        }
        let groups = Estimator.estimates(bySubfolder: candidates, of: root.path, options: IndexOptions(), countsOnly: true)
        #expect(groups[root.path]?.files == [.doc: 1])
        #expect(groups[root.appendingPathComponent("Кириллица").path]?.files == [.doc: 2])
        #expect(groups[root.appendingPathComponent("Second").path]?.files == [.doc: 1])
    }

    @Test func defaultDetailedEstimateStillMeasuresWork() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-counts-\(UUID().uuidString)")
        let files = [
            Candidate(
                path: root.appendingPathComponent("note.txt").path, kind: .doc,
                size: 8000, mtime: 1, inode: 0, device: 0)
        ]
        let detailed = Estimator.estimates(bySubfolder: files, of: root.path, options: IndexOptions())[root.path]
        #expect(detailed?.docChunks == 4)
        #expect((detailed?.seconds ?? 0) > 0)
        #expect(detailed?.files == [.doc: 1])
    }
}
