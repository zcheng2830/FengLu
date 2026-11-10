import Foundation

enum LyricsParser {
    private static let timeTagPattern = #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?(?:-\d+)?\]"#
    // Tolerates "[offset: +500]", "[offset:-250.5]" and "[offset:+ 500]".
    private static let offsetPattern = #"^\[\s*offset\s*:\s*([+-]?)\s*(\d+(?:\.\d+)?)\s*\]$"#

    private static let timeTagExpression = try? NSRegularExpression(pattern: timeTagPattern)
    private static let offsetExpression = try? NSRegularExpression(
        pattern: offsetPattern,
        options: [.caseInsensitive]
    )
    private static let unavailableLyricsKeys: Set<String> = [
        "no lyrics", "no lyric", "no lyrics available", "lyrics not available"
    ]
    private static let annotationBrackets: [Character: Character] = [
        "(": ")", "[": "]", "（": "）", "［": "］", "【": "】"
    ]
    private static let annotationClosingBrackets = Set(annotationBrackets.values)
    private static let closingSentencePunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "，", "。", "；", "：", "！", "？", "、", "…"]
    private static let flatAnnotationExpression = try! NSRegularExpression(
        pattern: #"\([^()\[\]（）［］【】]*\)|\[[^()\[\]（）［］【】]*\]|（[^()\[\]（）［］【】]*）|［[^()\[\]（）［］【】]*］|【[^()\[\]（）［］【】]*】"#
    )

    static func parse(
        _ text: String,
        sourceURL: URL?,
        sourceDescription: String
    ) -> LyricsDocument? {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedLyrics = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLyrics.isEmpty else {
            DebugLog.log("LyricsParser skipped empty text from \(sourceDescription)")
            return nil
        }

        var offset: TimeInterval = 0
        var timedRows: [(time: TimeInterval, text: String, ordinal: Int)] = []
        var plainRows: [String] = []

        for (ordinal, rawLine) in normalizedText.components(separatedBy: "\n").enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // The tag applies to the whole file wherever it appears, so the
            // offset is collected here and applied after every row is read.
            if let lineOffset = parseOffset(from: trimmedLine) {
                offset = lineOffset
                continue
            }

            let times = parseTimes(from: rawLine)
            if !times.isEmpty {
                let lineText = lyricTextAfterLastTimeTag(in: trimmedLine)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                timedRows.append(
                    contentsOf: times.map { time in
                        (time, lineText, ordinal)
                    }
                )
                continue
            }

            let parts = lyricLineParts(trimmedLine)
            if !parts.prefix.isEmpty && parts.content.isEmpty { continue }
            plainRows.append(parts.content)
        }

        if !timedRows.isEmpty {
            // LRC convention: a positive offset shows the lyrics earlier.
            let lines = timedRows
                .map { row in (time: max(row.time - offset, 0), text: row.text, ordinal: row.ordinal) }
                .sorted {
                    if $0.time == $1.time {
                        return $0.ordinal < $1.ordinal
                    }

                    return $0.time < $1.time
                }
                .enumerated()
                .map { index, row in
                    LyricsLine(id: index, time: row.time, text: row.text)
                }

            let timedLyricText = lines
                .map(\.text)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let plainText = timedLyricText.nonEmpty ?? trimmedLyrics
            DebugLog.log(
                "LyricsParser parsed synchronized lyrics from \(sourceDescription); " +
                "timedLines=\(lines.count), plainRows=\(plainRows.count)"
            )
            return LyricsDocument(
                sourceURL: sourceURL,
                sourceDescription: sourceDescription,
                lines: lines,
                plainText: plainText,
                isSynchronized: true
            )
        }

        let lines = plainRows
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, text in
                LyricsLine(id: index, time: nil, text: text)
            }

        guard !lines.isEmpty else {
            DebugLog.log("LyricsParser produced no displayable lines from \(sourceDescription)")
            return nil
        }

        DebugLog.log("LyricsParser parsed plain lyrics from \(sourceDescription); lines=\(lines.count)")
        return LyricsDocument(
            sourceURL: sourceURL,
            sourceDescription: sourceDescription,
            lines: lines,
            plainText: plainRows.joined(separator: "\n"),
            isSynchronized: false
        )
    }

    static func looksUsable(_ text: String) -> Bool {
        looksUsable(text, contentLineCount: contentLineCount(text))
    }

    static func contentLineCount(_ text: String) -> Int {
        text.components(separatedBy: .newlines)
            .map(lyricContentLine)
            .filter { !$0.isEmpty && !lyricContentLineLooksLikeNonLyric($0) }
            .count
    }

    static func looksUsable(_ text: String, contentLineCount: Int) -> Bool {
        let trimmedLyrics = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLyrics.isEmpty else {
            return false
        }

        if lyricsStringLooksLikePageChrome(trimmedLyrics) {
            return false
        }

        let lowerLyrics = trimmedLyrics.lowercased()
        let rejectedChromeStrings = [
            "contributor",
            "contributors",
            "embed",
            "you might also like",
            "we do not have the lyrics",
            "lyrics not available",
            "no lyrics available"
        ]

        for rejectedString in rejectedChromeStrings where lowerLyrics == rejectedString ||
            lowerLyrics.hasSuffix(" \(rejectedString)") ||
            lowerLyrics.hasPrefix("\(rejectedString) ") {
            return false
        }

        let hasTimestamp = timeTagExpression?.firstMatch(
            in: trimmedLyrics,
            range: NSRange(trimmedLyrics.startIndex..<trimmedLyrics.endIndex, in: trimmedLyrics)
        ) != nil

        guard contentLineCount > 0 else {
            return false
        }

        if hasTimestamp {
            return true
        }

        return trimmedLyrics.count >= 20
    }

    private static func parseTimes(from line: String) -> [TimeInterval] {
        guard let timeTagExpression else {
            return []
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return timeTagExpression.matches(in: line, range: range).compactMap { match in
            parseTime(from: line, match: match)
        }
    }

    private static func parseTime(from line: String, match: NSTextCheckingResult) -> TimeInterval? {
        guard let minuteRange = Range(match.range(at: 1), in: line),
              let secondRange = Range(match.range(at: 2), in: line),
              let minutes = Double(line[minuteRange]),
              let seconds = Double(line[secondRange])
        else {
            return nil
        }

        let fractionalSeconds: Double
        if match.range(at: 3).location != NSNotFound,
           let fractionRange = Range(match.range(at: 3), in: line) {
            fractionalSeconds = Double("0.\(line[fractionRange])") ?? 0
        } else {
            fractionalSeconds = 0
        }

        return minutes * 60 + seconds + fractionalSeconds
    }

    private static func lyricTextAfterLastTimeTag(in line: String) -> String {
        guard let timeTagExpression else {
            return line
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let lastMatch = timeTagExpression.matches(in: line, range: range).last,
              let textRange = Range(
                  NSRange(
                      location: NSMaxRange(lastMatch.range),
                      length: line.utf16.count - NSMaxRange(lastMatch.range)
                  ),
                  in: line
              )
        else {
            return line
        }

        return String(line[textRange])
    }

    private static func parseOffset(from line: String) -> TimeInterval? {
        guard let offsetExpression else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = offsetExpression.firstMatch(in: line, range: range),
              let signRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line),
              let milliseconds = Double(line[valueRange])
        else {
            return nil
        }

        return (line[signRange] == "-" ? -milliseconds : milliseconds) / 1000
    }

    private static func lyricsStringLooksLikePageChrome(_ text: String) -> Bool {
        let normalizedText = LyricsTextNormalization.key(text)
        let markers = [
            "privacy policy",
            "cookie policy",
            "top lyrics",
            "top artistas",
            "letras nuevas",
            "you might also like"
        ]

        return markers.filter { normalizedText.contains($0) }.count >= 2
    }

    static func lyricLineParts(_ rawLine: String) -> (prefix: String, content: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var remaining = line[...]
        while remaining.first == "[" {
            let body = remaining.dropFirst()
            guard let close = body.firstIndex(where: { $0 == "[" || $0 == "]" }),
                  body[close] == "]" else { break }
            let tag = String(remaining[...close])
            // Availability notes are content, even when written like a tag.
            guard !lyricContentLineLooksLikePlaceholder(tag) else { break }
            remaining = remaining[remaining.index(after: close)...].drop(while: \.isWhitespace)
        }
        return (String(line[..<remaining.startIndex]), String(remaining))
    }

    static func lyricContentLine(_ rawLine: String) -> String {
        lyricLineParts(rawLine).content
    }

    static func lyricContentLineLooksLikeNonLyric(_ line: String) -> Bool {
        lyricContentLineLooksLikeCredit(line) || lyricContentLineLooksLikePlaceholder(line)
    }

    private static func lyricContentLineLooksLikeCredit(_ line: String) -> Bool {
        let lowerLine = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerLine.isEmpty else {
            return true
        }

        let creditPrefixes = [
            "lyrics",
            "lyrics by",
            "lyricist",
            "composer",
            "music",
            "written by",
            "words by",
            "music by",
            "arranged by",
            "producer",
            "produced by",
            "vocals",
            "singer",
            "performed by",
            "作词",
            "作曲",
            "编曲",
            "編曲",
            "制作人",
            "製作人",
            "演唱",
            "歌手",
            "作詞",
            "作曲家",
            "편곡",
            "작사",
            "작곡"
        ]

        return creditPrefixes.contains { prefix in
            lowerLine == prefix ||
                lowerLine.hasPrefix("\(prefix):") ||
                lowerLine.hasPrefix("\(prefix) :") ||
                lowerLine.hasPrefix("\(prefix)：") ||
                lowerLine.hasPrefix("\(prefix) -") ||
                lowerLine.hasPrefix("\(prefix) by ")
        }
    }

    /// Remove unavailable-lyrics markers while preserving stage notes and other text.
    static func removingPlaceholderAnnotations(from line: String) -> (text: String, removed: Bool) {
        if unavailableLyricsKeys.contains(LyricsTextNormalization.key(line)) { return ("", true) }

        struct TextBuffer {
            var text = ""
            var removed = false
            var pendingSeparator = false
            var hadBoundaryWhitespace = false

            mutating func append(_ part: String, edited: Bool = false) {
                removed = removed || edited
                if pendingSeparator && part.first?.isWhitespace == true {
                    hadBoundaryWhitespace = true
                }
                let suffix = pendingSeparator ? part.drop(while: \.isWhitespace) : part[...]
                guard !suffix.isEmpty else { return }
                if pendingSeparator && hadBoundaryWhitespace && !text.isEmpty,
                   let next = suffix.first, !LyricsParser.isClosingPunctuation(next) {
                    text.append(" ")
                }
                pendingSeparator = false
                hadBoundaryWhitespace = false
                text += suffix
            }

            mutating func removeMarker() {
                hadBoundaryWhitespace = hadBoundaryWhitespace || text.last?.isWhitespace == true
                while text.last?.isWhitespace == true { text.removeLast() }
                removed = true
                pendingSeparator = true
            }
        }
        struct Annotation {
            let opening: Character
            let closing: Character
            var output = TextBuffer()
        }
        var annotations: [Annotation] = []
        var output = TextBuffer()
        func withCurrentBuffer(_ update: (inout TextBuffer) -> Void) {
            if annotations.isEmpty {
                update(&output)
            } else {
                update(&annotations[annotations.count - 1].output)
            }
        }
        func append(_ part: String, edited: Bool = false) {
            withCurrentBuffer { $0.append(part, edited: edited) }
        }
        func finish(_ annotation: Annotation, closed: Bool) {
            let content = annotation.output.text
            if (closed && unavailableLyricsKeys.contains(LyricsTextNormalization.key(content))) ||
                (annotation.output.removed && content.isEmpty) {
                withCurrentBuffer { $0.removeMarker() }
            } else {
                append(String(annotation.opening) + content + (closed ? String(annotation.closing) : ""),
                       edited: annotation.output.removed)
            }
        }
        func appendOverflow(_ remainder: String) {
            // At the nesting limit, a flat scan still removes complete markers.
            // It does not interpret the surrounding malformed/deep structure.
            var cursor = remainder.startIndex
            for match in flatAnnotationExpression.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)) {
                guard let range = Range(match.range, in: remainder),
                      unavailableLyricsKeys.contains(LyricsTextNormalization.key(String(remainder[range].dropFirst().dropLast()))) else { continue }
                append(String(remainder[cursor..<range.lowerBound]))
                withCurrentBuffer { $0.removeMarker() }
                cursor = range.upperBound
            }
            append(String(remainder[cursor...]))
        }
        // Process balanced groups from the inside out without recursion. Stray
        // brackets remain literal text and cannot hide a separate valid marker.
        for index in line.indices {
            let character = line[index]
            if let closing = annotationBrackets[character] {
                guard annotations.count < 32 else {
                    appendOverflow(String(line[index...]))
                    break
                }
                annotations.append(Annotation(opening: character, closing: closing))
            } else if annotationClosingBrackets.contains(character), annotations.last?.closing == character {
                finish(annotations.removeLast(), closed: true)
            } else {
                append(String(character))
            }
        }
        // Keep meaningful unmatched text, but omit an opener emptied by removal.
        while let annotation = annotations.popLast() {
            finish(annotation, closed: false)
        }
        return (output.text, output.removed)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        closingSentencePunctuation.contains(character) || character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .closePunctuation || $0.properties.generalCategory == .finalPunctuation
        }
    }

    static func lyricContentLineLooksLikePlaceholder(_ line: String) -> Bool {
        let normalizedLine = LyricsTextNormalization.key(line)
        let rejectedNormalizedLines = [
            "pure music",
            "pure music please listen",
            "pure music please enjoy",
            "pure music please appreciate",
            "instrumental",
            "instrumental music",
            "instrumental please listen",
            "this song is instrumental"
        ]

        if unavailableLyricsKeys.contains(normalizedLine) || rejectedNormalizedLines.contains(normalizedLine) {
            return true
        }

        let compactLine = normalizedLine.replacingOccurrences(of: " ", with: "")

        let rejectedCompactLines = [
            "puremusic",
            "puremusicpleaselisten",
            "puremusicpleaseenjoy",
            "puremusicpleaseappreciate",
            "\u{7EAF}\u{97F3}\u{4E50}\u{8BF7}\u{6B23}\u{8D4F}",
            "\u{7D14}\u{97F3}\u{6A02}\u{8ACB}\u{6B23}\u{8CDE}"
        ]

        return rejectedCompactLines.contains(compactLine)
    }

}
