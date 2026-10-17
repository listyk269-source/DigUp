import Foundation

/// Groups confirmed, current observations before pagination. Exact UTF-8 paths identify files: do not
/// case-fold or normalize Unicode, which could merge different files on a case-sensitive volume.
public enum FacePeopleAlbum {
    /// Preserve the camera-local written day. File-date fallback uses the machine's calendar.
    /// The UTC sort key compares those calendar components, without inventing an EXIF time zone.
    public struct MediaDate: Equatable, Sendable {
        public let day: String
        public let year: Int
        public let source: String
        public let sortKey: Double
    }
    public struct Period: Equatable, Sendable {
        public let from: Int?
        public let through: Int?
        public init(from: Int? = nil, through: Int? = nil) throws {
            guard from.map({ (1...9999).contains($0) }) ?? true,
                  through.map({ (1...9999).contains($0) }) ?? true,
                  from == nil || through == nil || from! <= through! else { throw Failure.invalidPeriod }
            self.from = from; self.through = through
        }
        func accepts(_ date: MediaDate?) -> Bool {
            if from == nil && through == nil { return true }
            guard let date else { return false }
            return (from == nil || date.year >= from!) && (through == nil || date.year <= through!)
        }
    }
    public enum Failure: Error { case invalidPeriod }
    public static func date(captured: String?, modified: Double) -> MediaDate? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        if let captured {
            let bytes = Array(captured.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            if bytes.count == 19, bytes[4] == 58, bytes[7] == 58, bytes[10] == 32, bytes[13] == 58, bytes[16] == 58 {
                func number(_ start: Int, _ end: Int) -> Int? {
                    let part = bytes[start..<end]; guard part.allSatisfy({ (48...57).contains($0) }) else { return nil }
                    return part.reduce(0) { $0 * 10 + Int($1 - 48) }
                }
                if let year = number(0, 4), (1...9999).contains(year), let month = number(5, 7), let day = number(8, 10),
                   let hour = number(11, 13), let minute = number(14, 16), let second = number(17, 19) {
                    let expected = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
                    let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
                    if let date = calendar.date(from: expected), fields.allSatisfy({ calendar.component($0, from: date) == expected.value(for: $0) }) {
                        return MediaDate(day: String(format: "%04d-%02d-%02d", year, month, day), year: year, source: "taken", sortKey: date.timeIntervalSince1970)
                    }
                }
            }
        }
        guard modified.isFinite, modified >= -62_135_596_800, modified < 253_402_300_800 else { return nil }
        let parts = MediaCalendar.fileComponents(modified)
        guard let year = parts.year, (1...9999).contains(year), let month = parts.month, let day = parts.day,
              let date = calendar.date(from: parts) else { return nil }
        return MediaDate(day: String(format: "%04d-%02d-%02d", year, month, day), year: year, source: "modified", sortKey: date.timeIntervalSince1970 + modified - floor(modified))
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
