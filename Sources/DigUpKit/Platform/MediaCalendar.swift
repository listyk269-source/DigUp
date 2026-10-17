import Foundation
#if os(Windows)
import WinSDK
#endif

/// Match the OS's displayed file date. Foundation's current zone can fall back to GMT in a
/// packaged Windows runtime; Windows performs its own historical daylight-saving conversion.
enum MediaCalendar {
    static func fileComponents(_ timestamp: Double) -> DateComponents {
        #if os(Windows)
        var utcCalendar = Calendar(identifier: .gregorian); utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: timestamp))
        var utc = SYSTEMTIME(), local = SYSTEMTIME()
        utc.wYear = WORD(parts.year!); utc.wMonth = WORD(parts.month!); utc.wDay = WORD(parts.day!)
        utc.wHour = WORD(parts.hour!); utc.wMinute = WORD(parts.minute!); utc.wSecond = WORD(parts.second!)
        if SystemTimeToTzSpecificLocalTimeEx(nil, &utc, &local) {
            return DateComponents(year: Int(local.wYear), month: Int(local.wMonth), day: Int(local.wDay),
                                  hour: Int(local.wHour), minute: Int(local.wMinute), second: Int(local.wSecond))
        }
        #endif
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: timestamp))
    }
}
