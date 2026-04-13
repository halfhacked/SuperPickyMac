import Testing
import Foundation
@testable import SuperPicky

@Suite struct DirectoryScannerTests {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func findsRAWFiles() throws {
        let tempDir = try makeTempDir()
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("IMG_001.CR3").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("IMG_002.NEF").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("IMG_003.ARW").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("readme.txt").path, contents: nil)

        let scanner = DirectoryScanner()
        let files = try scanner.scan(folder: tempDir)
        #expect(files.count == 3)
    }

    @Test func findsJPEGAndHEIF() throws {
        let tempDir = try makeTempDir()
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("photo.jpg").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("photo.HEIC").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("photo.hif").path, contents: nil)

        let scanner = DirectoryScanner()
        let files = try scanner.scan(folder: tempDir)
        #expect(files.count == 3)
    }

    @Test func emptyFolder() throws {
        let tempDir = try makeTempDir()
        let scanner = DirectoryScanner()
        let files = try scanner.scan(folder: tempDir)
        #expect(files.count == 0)
    }
}
