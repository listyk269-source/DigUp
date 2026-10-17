import Foundation

/// Groups confirmed, current observations before pagination. Exact UTF-8 paths identify files: do not
/// case-fold or normalize Unicode, which could merge different files on a case-sensitive volume.
public enum FacePeopleAlbum {
    public typealias MediaDate = MediaDates.MediaDate
    public typealias Period = MediaDates.Period
    public typealias Failure = MediaDates.Failure
    public static func date(captured: String?, modified: Double) -> MediaDate? {
        MediaDates.date(captured: captured, modified: modified)
    }
    public enum Order: String, Sendable { case indexed, newest = "date_desc", oldest = "date_asc" }
    public enum Media: String, Sendable {
        case all, photo, video
        func accepts(_ kind: String) -> Bool {
            self == .all || (self == .photo && ["image", "screenshot"].contains(kind)) || (self == .video && kind == "video")
        }
    }
    public struct File: Equatable, Sendable {
        public let representativeID: Int64
        public let observationCount: Int
    }

    public static func files(_ observations: [(id: Int64, path: String, kind: String, modified: Double)],
                             order: Order = .indexed, media: Media = .all, dates: [Data: MediaDate] = [:], period: Period? = nil) -> [File] {
        var grouped: [Data: (id: Int64, count: Int, modified: Double)] = [:]
        for observation in observations where media.accepts(observation.kind) {
            let key = Data(observation.path.utf8)
            let date = dates[key]
            guard period?.accepts(date) ?? true else { continue }
            if let previous = grouped[key] {
                grouped[key] = (min(previous.id, observation.id), previous.count + 1, previous.modified)
            } else {
                grouped[key] = (observation.id, 1, date?.sortKey ?? (observation.modified.isFinite ? observation.modified : 0))
            }
        }
        return grouped.values.sorted {
            if order != .indexed && $0.modified != $1.modified {
                return order == .newest ? $0.modified > $1.modified : $0.modified < $1.modified
            }
            return $0.id < $1.id // A stable tie-break keeps equal dates from moving across page boundaries.
        }.map { File(representativeID: $0.id, observationCount: $0.count) }
    }
}
