import Foundation

/// An explicit negative example for one person, independent of the continued existence of its source file.
/// Descriptors are local, model-specific and never returned to the UI. A rule only filters suggestions.
public struct FacePeopleExclusionRule: Codable, Sendable, Equatable {
    public let id: String
    public let personID: String
    public let source: FacePersonSnapshot
    public let embedding: [Float]
    public let minimum: Double
    public let created: Double
    public init(person: String, seed: IndexedFace, minimum: Double) {
        id = UUID().uuidString; personID = person; source = FacePersonSnapshot(seed)
        embedding = seed.face.embedding; self.minimum = minimum; created = Date().timeIntervalSince1970
    }
    public func matches(_ vector: [Float], model: String = FaceModels.modelID) -> Bool {
        source.model == model && (FaceIndexStore.cosine(embedding, vector) ?? -2) >= minimum
    }
    public var valid: Bool {
        !id.isEmpty && !personID.isEmpty && !source.model.isEmpty && !source.anchor.isEmpty && created.isFinite && minimum.isFinite && (-1...1).contains(minimum)
            && embedding.count == 128 && embedding.allSatisfy(\.isFinite)
            && abs(embedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.02
    }
}
