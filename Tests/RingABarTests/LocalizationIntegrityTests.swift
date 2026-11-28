import Foundation
import Testing

struct LocalizationIntegrityTests {
    @Test func allStringLocalizedLiteralsExistInSimplifiedChineseTable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stringsURL = root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let table = try #require(NSDictionary(contentsOf: stringsURL) as? [String: String])

        let sourcesURL = root.appendingPathComponent("Sources/RingABar")
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: nil
        ))

        let literalPattern = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:[^"\\]|\\.)*)"#)
        var missing: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(content.startIndex..., in: content)
            for match in literalPattern.matches(in: content, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: content) else { continue }
                let raw = String(content[keyRange])
                let candidates = normalizedKeyCandidates(for: raw)
                if !candidates.contains(where: { table[$0] != nil }) {
                    missing.append("\(fileURL.lastPathComponent): \(raw)")
                }
            }
        }

        #expect(missing.isEmpty, "Missing zh-Hans Localizable.strings entries:\n\(missing.joined(separator: "\n"))")
    }

    private func normalizedKeyCandidates(for raw: String) -> [String] {
        // Unescape literal quotes if any, then normalize Swift string interpolation.
        let unescaped = raw.replacingOccurrences(of: #"\""#, with: "\"")
        var segments: [String] = []
        var cursor = unescaped.startIndex
        var interpolations = 0

        while let start = unescaped[cursor...].range(of: #"\("#) {
            segments.append(String(unescaped[cursor..<start.lowerBound]))
            var depth = 1
            var index = start.upperBound
            while index < unescaped.endIndex && depth > 0 {
                let ch = unescaped[index]
                if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
                index = unescaped.index(after: index)
            }
            interpolations += 1
            cursor = index
        }
        segments.append(String(unescaped[cursor...]))
        guard interpolations > 0 else { return [unescaped] }

        // Escape literal '%' in static segments when building format strings.
        let escapedSegments = segments.map { $0.replacingOccurrences(of: "%", with: "%%") }
        let specifiers = ["%@", "%lld"]
        var results = [escapedSegments[0]]
        for i in 1..<escapedSegments.count {
            var next: [String] = []
            for prefix in results {
                for spec in specifiers {
                    next.append(prefix + spec + escapedSegments[i])
                }
            }
            results = next
        }
        return [unescaped] + results
    }
}
