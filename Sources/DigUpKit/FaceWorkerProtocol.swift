import Foundation

/// A broken worker transport/protocol is a job failure, not evidence that any user's file is unreadable.
/// Only a correctly correlated explicit rejection may be persisted as a per-file failed attempt.
public enum FaceWorkerProtocol {
    public static let maximumReplyBytes = 16 << 20
    public struct RuntimeFailure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
    public struct FileFailure: Error, CustomStringConvertible {
        public let description = "The face runtime could not analyze this file. Retry after checking the model and runtime."
        public init() {}
    }

    public static func decode(_ line: Data) throws -> [String: Any] {
        guard line.count <= maximumReplyBytes else { throw RuntimeFailure("The face runtime response exceeded its limit.") }
        do {
            guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw RuntimeFailure("Invalid face runtime response.")
            }
            return reply
        } catch { throw RuntimeFailure("Invalid face runtime response.") }
    }

    public static func validate(_ reply: [String: Any], id: Int) throws {
        // Decode just the tiny header strictly: JSON true/1 and fractional identifiers are not interchangeable.
        struct Header: Decodable { let id: Int; let ok: Bool }
        let header: Header
        do {
            let data = try JSONSerialization.data(withJSONObject: ["id": reply["id"] ?? NSNull(), "ok": reply["ok"] ?? NSNull()])
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch { throw RuntimeFailure("The face runtime returned an invalid response header.") }
        guard header.id == id else { throw RuntimeFailure("The face runtime returned a response for another request.") }
        guard header.ok else { throw FileFailure() }
    }

    public static func observations(_ reply: [String: Any], location: Double?) throws -> [FaceObservation] {
        guard let rows = reply["faces"] as? [[String: Any]], rows.count <= 32 else {
            throw RuntimeFailure("The face runtime returned invalid face data.")
        }
        return try rows.map { row in
            guard let bbox = row["bbox"] as? [Double], let landmarks = row["landmarks"] as? [Double],
                  let score = row["score"] as? Double, let vector = row["embedding"] as? [Double] else {
                throw RuntimeFailure("The face runtime returned invalid face data.")
            }
            let face = FaceObservation(bbox: bbox, landmarks: landmarks, score: score, embedding: vector.map(Float.init), loc: location)
            guard face.isValid else { throw RuntimeFailure("The face runtime returned invalid face data.") }
            return face
        }
    }
}
