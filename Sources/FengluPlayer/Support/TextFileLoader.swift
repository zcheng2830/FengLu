import Foundation

enum TextFileLoader {
    /// Loads a text file, detecting its encoding.
    ///
    /// - Parameter prefersDecoding: Used only when the bytes are not Unicode and
    ///   decode cleanly in more than one legacy encoding. Playlist parsers pass
    ///   "does a referenced media file exist". When exactly one decoding is
    ///   accepted it wins; when several are (an ASCII file name reads the same
    ///   in every encoding), encoding detection chooses among them.
    static func load(_ url: URL, prefersDecoding: ((String) -> Bool)? = nil) throws -> String {
        let data = try Data(contentsOf: url)
        DebugLog.log("TextFileLoader loaded \(data.count) byte(s) from \(url.path)")
        let decoded = decode(data, prefersDecoding: prefersDecoding)
        let lineCount = decoded.text.components(separatedBy: .newlines).count
        DebugLog.log(
            "TextFileLoader decoded \(url.lastPathComponent) as \(decoded.encodingLabel); " +
            "\(decoded.text.count) character(s), \(lineCount) line(s)"
        )
        return decoded.text
    }

    static func decode(
        _ data: Data,
        prefersDecoding: ((String) -> Bool)? = nil
    ) -> (text: String, encodingLabel: String) {
        if let bom = byteOrderMark(in: data),
           let string = String(data: data.dropFirst(bom.length), encoding: bom.encoding) {
            return (strippingByteOrderMark(string), "\(label(bom.encoding)) BOM")
        }

        // BOM-less UTF-16 of mostly-ASCII text is also valid UTF-8 (full of NUL
        // characters), so it has to be recognised before UTF-8 is tried.
        for encoding in bomlessUTF16Encodings(for: data) {
            if let string = String(data: data, encoding: encoding) {
                return (strippingByteOrderMark(string), label(encoding))
            }
        }

        if let string = String(data: data, encoding: .utf8) {
            return (string, label(.utf8))
        }

        // Legacy multi-byte encodings fail on byte sequences they do not define,
        // so only the plausible ones survive. Windows-1252 accepts almost
        // anything and must therefore come last.
        let candidates: [(encoding: String.Encoding, text: String)] = legacyEncodings.compactMap { encoding in
            String(data: data, encoding: encoding).map { (encoding, $0) }
        }

        // A referenced file that exists only settles the question when exactly one
        // decoding finds it. An ASCII file name ("album.wav") reads the same in
        // every encoding, so several decodings can be accepted; detection then
        // chooses among those instead of the first one in candidate order.
        var pool = candidates
        if let prefersDecoding {
            let preferred = candidates.filter { prefersDecoding($0.text) }
            if preferred.count == 1, let only = preferred.first {
                return (only.text, "\(label(only.encoding)) (referenced file found)")
            }

            if !preferred.isEmpty {
                pool = preferred
            }
        }

        if let detected = detectedEncoding(for: data, among: pool.map(\.encoding)),
           let match = pool.first(where: { $0.encoding == detected }) {
            return (match.text, "\(label(match.encoding)) (detected)")
        }

        if pool.count != candidates.count, let first = pool.first {
            return (first.text, "\(label(first.encoding)) (first candidate with referenced file)")
        }

        if let first = candidates.first {
            return (first.text, "\(label(first.encoding)) (first candidate)")
        }

        return (String(decoding: data, as: UTF8.self), "lossy utf8 fallback")
    }

    private static let gb18030 = encoding(for: .GB_18030_2000)
    private static let big5 = encoding(for: .big5)
    private static let eucKR = encoding(for: .EUC_KR)

    private static let legacyEncodings: [String.Encoding] = [
        gb18030,
        .shiftJIS,
        big5,
        eucKR,
        .windowsCP1252,
        .isoLatin1
    ]

    private static func encoding(for encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        )
    }

    private static func detectedEncoding(for data: Data, among encodings: [String.Encoding]) -> String.Encoding? {
        guard !encodings.isEmpty else {
            return nil
        }

        var converted: NSString?
        var usedLossyConversion: ObjCBool = false
        let rawValue = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: encodings.map { NSNumber(value: $0.rawValue) },
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false
            ],
            convertedString: &converted,
            usedLossyConversion: &usedLossyConversion
        )

        guard rawValue != 0, !usedLossyConversion.boolValue else {
            return nil
        }

        return String.Encoding(rawValue: rawValue)
    }

    private static func byteOrderMark(in data: Data) -> (encoding: String.Encoding, length: Int)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return (.utf8, 3)
        }

        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return (.utf16LittleEndian, 2)
        }

        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return (.utf16BigEndian, 2)
        }

        return nil
    }

    private static func strippingByteOrderMark(_ string: String) -> String {
        string.hasPrefix("\u{FEFF}") ? String(string.dropFirst()) : string
    }

    private static func bomlessUTF16Encodings(for data: Data) -> [String.Encoding] {
        var encodings: [String.Encoding] = []
        if looksLikeUTF16(data, zeroByteOffset: 1) {
            encodings.append(.utf16LittleEndian)
        }

        if looksLikeUTF16(data, zeroByteOffset: 0) {
            encodings.append(.utf16BigEndian)
        }

        return encodings
    }

    private static func looksLikeUTF16(_ data: Data, zeroByteOffset: Int) -> Bool {
        guard data.count >= 8 else {
            return false
        }

        let bytes = [UInt8](data.prefix(4096))
        let byteCount = bytes.count - (bytes.count % 2)
        var pairCount = 0
        var zeroCount = 0
        var index = 0

        while index + 1 < byteCount {
            if bytes[index + zeroByteOffset] == 0 {
                zeroCount += 1
            }

            pairCount += 1
            index += 2
        }

        guard pairCount > 0 else {
            return false
        }

        return Double(zeroCount) / Double(pairCount) > 0.45
    }

    private static func label(_ encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8:
            return "utf8"
        case .utf16LittleEndian:
            return "utf16LittleEndian"
        case .utf16BigEndian:
            return "utf16BigEndian"
        case .windowsCP1252:
            return "windowsCP1252"
        case .isoLatin1:
            return "isoLatin1"
        case .shiftJIS:
            return "shiftJIS"
        case gb18030:
            return "gb18030"
        case big5:
            return "big5"
        case eucKR:
            return "eucKR"
        default:
            return String(encoding.rawValue)
        }
    }
}
