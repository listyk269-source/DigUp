import Foundation

/// Shared indexed capture dates and inclusive calendar periods for search and People.
public enum MediaDates {
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
        public func accepts(_ date: MediaDate?) -> Bool {
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
}
