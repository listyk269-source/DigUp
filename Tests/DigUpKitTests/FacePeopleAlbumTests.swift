import DigUpKit
import Testing

@Suite struct FacePeopleAlbumTests {
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
