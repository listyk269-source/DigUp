import DigUpKit
import Foundation
import Testing

@Suite struct FacePeopleAlbumTests {
    @Test func cameraDateWinsOverCopyDateAndKeepsWrittenDay() {
        let copied = 1_768_000_000.0
        let date = FacePeopleAlbum.date(captured: "2000:12:31 23:59:59", modified: copied)
        #expect(date?.day == "2000-12-31" && date?.year == 2000 && date?.source == "taken")
        #expect(FacePeopleAlbum.date(captured: "2000:02:29 12:00:00", modified: copied)?.source == "taken")
        for malformed in ["2001:02:29 12:00:00", "2003:13:01 00:00:00", "0000:00:00 00:00:00", "2000:01:01 24:00:00", "2000:01:01 12:61:00", "2000:01:01 12:00:60", "", "2000-01-01", "garbage"] {
            #expect(FacePeopleAlbum.date(captured: malformed, modified: copied)?.source == "modified")
        }
        #expect(FacePeopleAlbum.date(captured: nil, modified: .nan) == nil)
        #expect(FacePeopleAlbum.date(captured: nil, modified: .greatestFiniteMagnitude) == nil)
    }
    @Test func yearPeriodIncludesBothEndsBeforePaging() throws {
        let observations: [Observation] = (1...100).map { (Int64($0), "D:/Фото/\($0).jpg", "image", 1_768_000_000) }
        let dates = Dictionary(uniqueKeysWithValues: observations.map { observation in
            (Data(observation.path.utf8), FacePeopleAlbum.date(captured: "\(1999 + Int(observation.id) % 6):12:31 23:59:59", modified: observation.modified)!)
        })
        let period = try FacePeopleAlbum.Period(from: 2000, through: 2003)
        let album = FacePeopleAlbum.files(observations, order: .oldest, dates: dates, period: period)
        #expect(album.count > 40)
        #expect(album.allSatisfy { (2000...2003).contains(dates[Data("D:/Фото/\($0.representativeID).jpg".utf8)]!.year) })
        #expect(album.contains { dates[Data("D:/Фото/\($0.representativeID).jpg".utf8)]!.year == 2000 })
        #expect(album.contains { dates[Data("D:/Фото/\($0.representativeID).jpg".utf8)]!.year == 2003 })
        #expect(FacePeopleAlbum.files(observations, dates: dates, period: try .init(from: 1900, through: 1901)).isEmpty)
        #expect(throws: FacePeopleAlbum.Failure.self) { try FacePeopleAlbum.Period(from: 2003, through: 2000) }
        #expect(throws: FacePeopleAlbum.Failure.self) { try FacePeopleAlbum.Period(from: 0) }
        #expect(throws: FacePeopleAlbum.Failure.self) { try FacePeopleAlbum.Period(through: 10000) }
    }
    private typealias Observation = (id: Int64, path: String, kind: String, modified: Double)
    @Test func groupsFacesAndVideoFramesBeforePaging() {
        let observations: [Observation] = (1...85).map { number in
            let video = number <= 43
            let path = video ? "D:/Фото/video.mp4" : "D:/Фото/снимок \(number).jpg"
            return (Int64(number), path, video ? "video" : "image", Double(video ? 1 : number))
        }
        let files = FacePeopleAlbum.files(Array(observations.reversed()))
        #expect(files.count == 43)
        #expect(files.first?.representativeID == 1 && files.first?.observationCount == 43)
        #expect(files.prefix(40).count == 40 && files.dropFirst(40).count == 3)
        #expect(files.last?.representativeID == 85)
    }
    @Test func exactUnicodeAndCaseSensitivePathsRemainDistinct() {
        let paths = ["D:/Фото Лысаченко/😀 café.jpg", "D:/Фото Лысаченко/😀 cafe\u{301}.jpg", "D:/Фото/a.jpg", "D:/Фото/A.jpg"]
        let files = FacePeopleAlbum.files(paths.enumerated().map { (id: Int64($0.offset + 1), path: $0.element, kind: "image", modified: 1.0) })
        #expect(files.count == 4 && files.allSatisfy { $0.observationCount == 1 })
        #expect(FacePeopleAlbum.files([]).isEmpty)
    }
    @Test func sortsCompleteFilteredAlbumsWithStableDateTies() {
        let observations: [Observation] = (1...85).map { number in
            let kind = number % 3 == 0 ? "video" : number % 3 == 1 ? "image" : "screenshot"
            return (Int64(number), "D:/Фото/\(number).jpg", kind, Double(number / 2))
        }
        let newest = FacePeopleAlbum.files(observations, order: .newest, media: .photo)
        let oldest = FacePeopleAlbum.files(Array(observations.reversed()), order: .oldest, media: .photo)
        #expect(newest.count == 57 && oldest.count == 57)
        #expect(newest.first?.representativeID == 85 && oldest.first?.representativeID == 1)
        #expect(newest.prefix(40).count == 40 && newest.dropFirst(40).count == 17)
        #expect(FacePeopleAlbum.files(Array(observations.reversed()), order: .newest, media: .photo) == newest)
        let videos = FacePeopleAlbum.files(observations, order: .oldest, media: .video)
        #expect(videos.count == 28 && videos.allSatisfy { $0.representativeID % 3 == 0 })
        #expect(FacePeopleAlbum.files([(id: 1, path: "single.jpg", kind: "image", modified: 1)], media: .video).isEmpty)
    }
}
