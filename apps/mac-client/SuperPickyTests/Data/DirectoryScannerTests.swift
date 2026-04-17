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

    @Test func recursesIntoSubdirectories() throws {
        let root = try makeTempDir()
        let sub1 = root.appendingPathComponent("Day1")
        let sub2 = root.appendingPathComponent("Day2/Nested")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: root.appendingPathComponent("top.ARW").path, contents: nil)
        FileManager.default.createFile(atPath: sub1.appendingPathComponent("a.ARW").path, contents: nil)
        FileManager.default.createFile(atPath: sub1.appendingPathComponent("b.arw").path, contents: nil)
        FileManager.default.createFile(atPath: sub2.appendingPathComponent("c.jpg").path, contents: nil)
        FileManager.default.createFile(atPath: sub2.appendingPathComponent("readme.txt").path, contents: nil)

        let files = try DirectoryScanner().scan(folder: root)
        let names = Set(files.map { $0.lastPathComponent })
        #expect(names == Set(["top.ARW", "a.ARW", "b.arw", "c.jpg"]))
    }

    @Test func sortsByParentThenName() throws {
        let root = try makeTempDir()
        let sub1 = root.appendingPathComponent("A")
        let sub2 = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: sub2.appendingPathComponent("x.ARW").path, contents: nil)
        FileManager.default.createFile(atPath: sub1.appendingPathComponent("z.ARW").path, contents: nil)
        FileManager.default.createFile(atPath: sub1.appendingPathComponent("a.ARW").path, contents: nil)

        let files = try DirectoryScanner().scan(folder: root)
        // A/a.ARW, A/z.ARW, B/x.ARW
        #expect(files[0].lastPathComponent == "a.ARW")
        #expect(files[1].lastPathComponent == "z.ARW")
        #expect(files[2].lastPathComponent == "x.ARW")
    }
}
