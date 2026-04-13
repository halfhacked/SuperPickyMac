import Foundation

/// Writes IPTC keywords to image files via exiftool subprocess.
enum KeywordWriter {

    enum WriterError: Error, Equatable {
        case fileNotFound
        case exiftoolNotFound
        case exiftoolFailed(String)
    }

    // MARK: - Public

    /// Writes IPTC keywords to a photo file, merging with any existing keywords.
    /// Clears existing IPTC:Keywords first, then writes the merged (deduplicated) set.
    static func write(keywords: [String], to filePath: String) throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw WriterError.fileNotFound
        }
        let exiftool = try findExiftool()

        // Read existing keywords and merge
        let existing = EXIFReader.read(from: filePath)?.keywords ?? []
        var seen = Set<String>()
        var merged: [String] = []
        for kw in existing + keywords {
            if seen.insert(kw).inserted {
                merged.append(kw)
            }
        }

        // Build args: clear then add each keyword
        var args = ["-overwrite_original", "-charset", "iptc=UTF8", "-IPTC:Keywords="]
        for kw in merged {
            args.append("-IPTC:Keywords=\(kw)")
        }
        args.append(filePath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftool)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WriterError.exiftoolFailed(output)
        }
    }

    /// Formats keywords from a template string by replacing placeholders with values.
    /// Each space-delimited token becomes a keyword; tokens with nil/empty values are skipped.
    static func formatKeywords(
        template: String,
        en: String? = nil,
        cn: String? = nil,
        latin: String? = nil,
        pinyin: String? = nil
    ) -> [String] {
        let tokens = template.split(separator: " ").map(String.init)
        return tokens.compactMap { token in
            let replaced: String?
            switch token {
            case "{en}": replaced = en
            case "{cn}": replaced = cn
            case "{latin}": replaced = latin
            case "{pinyin}": replaced = pinyin
            default: replaced = token
            }
            guard let value = replaced, !value.isEmpty else { return nil }
            return value
        }
    }

    // MARK: - Private

    private static let searchPaths = [
        "/opt/homebrew/bin/exiftool",
        "/usr/local/bin/exiftool",
        "/usr/bin/exiftool",
    ]

    private static func findExiftool() throws -> String {
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw WriterError.exiftoolNotFound
    }
}
