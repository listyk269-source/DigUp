import DigUpKit
import Testing

@Suite struct FacePeopleAlbumTests {
    @Test func groupsFacesAndVideoFramesBeforePaging() {
        let observations = (1...85).map { (id: Int64($0), path: $0 <= 43 ? "D:/Фото/video.mp4" : "D:/Фото/снимок \($0).jpg") }
        let files = FacePeopleAlbum.files(Array(observations.reversed()))
        #expect(files.count == 43)
        #expect(files.first?.representativeID == 1 && files.first?.observationCount == 43)
        #expect(files.prefix(40).count == 40 && files.dropFirst(40).count == 3)
        #expect(files.last?.representativeID == 85)
    }
    @Test func exactUnicodeAndCaseSensitivePathsRemainDistinct() {
        let paths = ["D:/Фото Лысаченко/😀 café.jpg", "D:/Фото Лысаченко/😀 cafe\u{301}.jpg", "D:/Фото/a.jpg", "D:/Фото/A.jpg"]
        let files = FacePeopleAlbum.files(paths.enumerated().map { (id: Int64($0.offset + 1), path: $0.element) })
        #expect(files.count == 4 && files.allSatisfy { $0.observationCount == 1 })
        #expect(FacePeopleAlbum.files([]).isEmpty)
    }
}
