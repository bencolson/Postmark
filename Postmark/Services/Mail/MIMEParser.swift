import Foundation

/// Minimal RFC 2045/2046 MIME walker with no third-party dependencies.
///
/// Mail's AppleScript attachment element (`every attachment of m`) errors -1728
/// for every message on macOS 26.6.2 — verified via bare `osascript`, not
/// Postmark — so the poller's attachment list is always empty. `source of m`
/// returns the full raw RFC822 message instead; this parser recovers attachment
/// name/data/size from that source, one resolution point upstream of every
/// consumer (Silo doc forward, receipt→Hubdoc forward, attachment classifier).
///
/// Conservative by design: a part is an attachment only if it carries an
/// explicit filename (`Content-Disposition: attachment; filename="…"` or
/// `Content-Type: …; name="…"`), matching Mail's own "attachments" semantics
/// (inline images without a filename are excluded). Filename-less leaves and
/// zero-length parts are skipped.
enum MIMEParser {

    fileprivate struct Part {
        var contentType = "text/plain"
        var boundary: String?
        var encoding: String?
        var dispositionFilename: String?
        var contentTypeName: String?
        var body = ""

        var filename: String? { dispositionFilename ?? contentTypeName }
    }

    /// Parse a raw RFC822 message and return its attachment parts.
    static func parse(source: String) -> [MailAttachment] {
        // CRLF → LF keeps line-based boundary and soft-break logic single-track.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var attachments: [MailAttachment] = []
        collectAttachments(from: Part(parsing: normalized), into: &attachments)
        return attachments
    }

    // MARK: - Tree walk

    private static func collectAttachments(from part: Part, into out: inout [MailAttachment]) {
        if part.contentType.hasPrefix("multipart/") {
            guard let boundary = part.boundary, !boundary.isEmpty else { return }
            for child in splitMultipart(body: part.body, boundary: boundary) {
                collectAttachments(from: child, into: &out)
            }
            return
        }
        guard let name = part.filename, !name.isEmpty else { return }
        guard let data = decodedBody(of: part) else { return }
        guard !data.isEmpty else { return }
        out.append(MailAttachment(name: name, size: data.count, data: data))
    }

    // MARK: - Part construction

    private static func splitMultipart(body: String, boundary: String) -> [Part] {
        let delimiter = "--\(boundary)"
        let terminator = "--\(boundary)--"
        var parts: [Part] = []
        var current: [String]?
        var inEpilogue = false
        for line in body.components(separatedBy: "\n") {
            if inEpilogue { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == delimiter || trimmed == terminator {
                if let buffer = current {
                    parts.append(Part(parsing: buffer.joined(separator: "\n")))
                }
                current = []
                if trimmed == terminator { inEpilogue = true }
                continue
            }
            current?.append(line)
        }
        if let buffer = current { parts.append(Part(parsing: buffer.joined(separator: "\n"))) }
        return parts
    }

    // MARK: - Header parsing

    private static func headersAndBody(_ text: String) -> (headers: [String], body: String) {
        guard let range = text.range(of: "\n\n") else { return (text.components(separatedBy: "\n"), "") }
        let headerText = String(text[..<range.lowerBound])
        let bodyText = String(text[range.upperBound...])
        return (headerText.components(separatedBy: "\n"), bodyText)
    }

    /// Unfold folded header line continuations so each logical header is one line.
    private static func logicalLines(_ raw: [String]) -> [String] {
        var out: [String] = []
        for line in raw {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                if !out.isEmpty {
                    out[out.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                }
            } else {
                out.append(line)
            }
        }
        return out
    }

    // MARK: - Body decoding

    private static func decodedBody(of part: Part) -> Data? {
        switch (part.encoding ?? "").lowercased() {
        case "base64":
            return Data(base64Encoded: part.body, options: [.ignoreUnknownCharacters])
        case "quoted-printable":
            return quotedPrintableDecoded(part.body)
        default:
            // 7bit, 8bit, binary, or absent → raw bytes.
            return Data(part.body.utf8)
        }
    }

    private static func quotedPrintableDecoded(_ body: String) -> Data {
        let bytes = Array(body.utf8)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    // Soft line break ("=\n", CRLF already normalized) — drop both.
                    i += 2
                    continue
                }
                if i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                    out.append((hi << 4) | lo)
                    i += 3
                    continue
                }
                out.append(0x3D) // literal '=' (unknown escape)
                i += 1
                continue
            }
            out.append(b)
            i += 1
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    // MARK: - Parameter parsing

    /// Split `;`-separated parameters honoring quoted strings (filenames may
    /// legitimately contain `;`).
    private static func splitParameters(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in value {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ";" && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return s }
        return String(s.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Extract parameters from a `;`-separated header value.
    private static func parameters(of value: String) -> [String: String] {
        var params: [String: String] = [:]
        for segment in splitParameters(value) {
            let seg = segment.trimmingCharacters(in: .whitespaces)
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let key = String(seg[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            if key.isEmpty { continue }
            let raw = String(seg[seg.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            params[key] = unquote(raw)
        }
        return params
    }
}

// MARK: - Part init from a raw header+body block

private extension MIMEParser.Part {
    init(parsing text: String) {
        let (headerRows, bodyText) = MIMEParser.headersAndBody(text)
        body = bodyText

        for line in MIMEParser.logicalLines(headerRows) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let params = MIMEParser.parameters(of: value)

            switch key {
            case "content-type":
                let typeToken = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
                contentType = typeToken.trimmingCharacters(in: .whitespaces).lowercased()
                boundary = params["boundary"]
                contentTypeName = params["name"]
            case "content-disposition":
                dispositionFilename = params["filename"]
            case "content-transfer-encoding":
                encoding = value
            default:
                break
            }
        }
    }
}