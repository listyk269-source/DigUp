import Foundation
import Testing
@testable import DigUpKit

@Suite struct FaceWorkerProtocolTests {
    @Test func explicitCorrelatedRejectionIsTheOnlyPerFileFailure() throws {
        let success = try FaceWorkerProtocol.decode(Data(#"{"id":7,"ok":true,"faces":[]}"#.utf8))
        try FaceWorkerProtocol.validate(success, id: 7)
        #expect(try FaceWorkerProtocol.observations(success, location: nil).isEmpty)
        let rejected = try FaceWorkerProtocol.decode(Data(#"{"id":7,"ok":false,"error":"unreadable"}"#.utf8))
        #expect(throws: FaceWorkerProtocol.FileFailure.self) { try FaceWorkerProtocol.validate(rejected, id: 7) }
        // A rejection for another request is a broken protocol, never evidence about the current file.
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) { try FaceWorkerProtocol.validate(rejected, id: 8) }
    }

    @Test(arguments: ["{truncated", "[]", "null", "\"text\""])
    func malformedReplyIsFatal(_ json: String) {
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) { try FaceWorkerProtocol.decode(Data(json.utf8)) }
    }

    @Test(arguments: [#"{"ok":true}"#, #"{"id":7}"#, #"{"id":7.5,"ok":true}"#,
                      #"{"id":true,"ok":true}"#, #"{"id":7,"ok":1}"#, #"{"id":"7","ok":true}"#])
    func invalidHeaderCannotPoisonAFileVersion(_ json: String) throws {
        let reply = try FaceWorkerProtocol.decode(Data(json.utf8))
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) { try FaceWorkerProtocol.validate(reply, id: 7) }
    }

    @Test func boundedReplyAndInvalidAnalysisPayloadAreFatal() {
        let oversized = Data(repeating: 32, count: FaceWorkerProtocol.maximumReplyBytes + 1)
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) { try FaceWorkerProtocol.decode(oversized) }
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) { try FaceWorkerProtocol.observations([:], location: nil) }
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) {
            try FaceWorkerProtocol.observations(["faces": [["bbox": [0, 0, 1, 1]]]], location: nil)
        }
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) {
            try FaceWorkerProtocol.observations(["faces": Array(repeating: [String: Any](), count: 33)], location: nil)
        }
    }

    @Test func validatedObservationKeepsActualFrameLocationAndRejectsInvalidVector() throws {
        var vector = [Double](repeating: 0, count: 128); vector[0] = 1
        var row: [String: Any] = ["bbox": [0.1, 0.2, 0.3, 0.4], "landmarks": [Double](repeating: 0.3, count: 10),
                                  "score": 0.9, "embedding": vector]
        let faces = try FaceWorkerProtocol.observations(["faces": [row]], location: 12.5)
        #expect(faces.count == 1 && faces[0].isValid && faces[0].loc == 12.5)
        vector[0] = .infinity; row["embedding"] = vector
        #expect(throws: FaceWorkerProtocol.RuntimeFailure.self) { try FaceWorkerProtocol.observations(["faces": [row]], location: nil) }
    }
}
