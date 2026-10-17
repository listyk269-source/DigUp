import Foundation

/// Groups confirmed, current observations before pagination. Exact UTF-8 paths identify files: do not
/// case-fold or normalize Unicode, which could merge different files on a case-sensitive volume.
public enum FacePeopleAlbum {
    public struct File: Equatable, Sendable {
        public let representativeID: Int64
        public let observationCount: Int
    }

    public static func files(_ observations: [(id: Int64, path: String)]) -> [File] {
        var grouped: [Data: (id: Int64, count: Int)] = [:]
        for observation in observations {
            let key = Data(observation.path.utf8)
            if let previous = grouped[key] {
                grouped[key] = (min(previous.id, observation.id), previous.count + 1)
            } else {
                grouped[key] = (observation.id, 1)
            }
        }
        return grouped.values.map { File(representativeID: $0.id, observationCount: $0.count) }
            .sorted { $0.representativeID < $1.representativeID }
    }
}
