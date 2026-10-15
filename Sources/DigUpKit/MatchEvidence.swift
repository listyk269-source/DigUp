import Foundation

/// Evidence available in the existing local index. Face recognition is intentionally not inferred from an image vector.
public enum MatchType: String, CaseIterable, Codable, Sendable {
    case visual, face, audio, ocr, metadata
}

/// Cosine is a same-modality embedding score, not a probability or a share of total similarity.
/// A metadata match has a literal value instead of a numerical score. Locations are only supplied for actual segments.
public struct MatchEvidence: Sendable {
    public let type: MatchType
    public let cosine: Double?
    public let seedSegment: Int64?
    public let segment: Int64?
    public let seedLoc: Double?
    public let loc: Double?
    public let locEnd: Double?
    public let value: String?
}
