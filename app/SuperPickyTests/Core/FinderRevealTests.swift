import Testing
import Foundation
@testable import SuperPicky

@MainActor
struct FinderRevealTests {
    final class RecordingRevealer: FinderRevealer {
        var recorded: [URL] = []
        func reveal(_ urls: [URL]) {
            recorded.append(contentsOf: urls)
        }
    }

    @Test
    func revealsPhotoFilePathAsURL() {
        let original = FinderReveal.revealer
        defer { FinderReveal.revealer = original }

        let fake = RecordingRevealer()
        FinderReveal.revealer = fake

        let photo = Photo(
            filename: "test.arw",
            filePath: "/tmp/superpicky/test.arw",
            folderPath: "/tmp/superpicky"
        )
        FinderReveal.reveal(photo)

        #expect(fake.recorded == [URL(fileURLWithPath: "/tmp/superpicky/test.arw")])
    }
}
