import Foundation

/// Edits the `statusLine` entry of Claude Code's settings.json as text, so the
/// rest of the user's file (key order, indentation, everything else) is left
/// byte-for-byte alone. Every edit is re-parsed and compared against the
/// expected result before it is returned; if anything else changed, it throws.
///
/// Pure functions over `Data`: no file access here.
enum SettingsEditor {
    enum EditError: Error {
        /// The file isn't a JSON object. We refuse to touch it.
        case notJSONObject
        /// `statusLine` (or its `command`) appears more than once. Parsers
        /// disagree on which one wins, so an edit could miss the one Claude
        /// Code actually uses.
        case duplicateKeys
        /// The edit didn't produce exactly the change we intended.
        case verificationFailed
    }

    /// The current `statusLine.command`, or nil if there is none.
    /// Throws if the file exists but isn't a JSON object.
    static func statusLineCommand(in data: Data?) throws -> String? {
        guard let data = data, let root = try parse(data) else { return nil }
        _ = try scan(data)
        return (root["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// Returns the settings with `statusLine.command` set to `command`. Other
    /// fields of an existing `statusLine` (padding and so on) are kept.
    static func settingStatusLineCommand(_ command: String, in data: Data?) throws -> Data {
        guard let data = data, let root = try parse(data) else {
            return Data("{\n  \"statusLine\": \(freshStatusLine(command, indent: "  "))\n}\n".utf8)
        }
        let (bytes, open, members, close) = try scan(data)
        let indent = memberIndent(bytes, members: members)
        var expected = root
        var edited = bytes

        if let existing = members.first(where: { $0.key == "statusLine" }) {
            if var statusLine = root["statusLine"] as? [String: Any], statusLine["command"] is String,
               let (inner, _) = Self.members(bytes, objectAt: existing.valueStart),
               let commandMember = inner.first(where: { $0.key == "command" }) {
                // Swap just the command string.
                edited.replaceSubrange(commandMember.valueStart..<commandMember.valueEnd, with: jsonString(command))
                statusLine["command"] = command
                expected["statusLine"] = statusLine
            } else {
                // Present but not something we can chain; replace it whole.
                edited.replaceSubrange(existing.valueStart..<existing.valueEnd,
                                       with: Array(freshStatusLine(command, indent: indent).utf8))
                expected["statusLine"] = ["type": "command", "command": command]
            }
        } else {
            let entry = "\"statusLine\": \(freshStatusLine(command, indent: indent))"
            if let last = members.last {
                edited.insert(contentsOf: Array(",\n\(indent)\(entry)".utf8), at: last.valueEnd)
            } else {
                edited.replaceSubrange((open + 1)..<close, with: Array("\n\(indent)\(entry)\n".utf8))
            }
            expected["statusLine"] = ["type": "command", "command": command]
        }
        return try verified(edited, equals: expected)
    }

    /// Returns the settings with the `statusLine` entry removed.
    static func removingStatusLine(in data: Data) throws -> Data {
        guard let root = try parse(data) else { throw EditError.notJSONObject }
        let (bytes, open, members, close) = try scan(data)
        guard let index = members.firstIndex(where: { $0.key == "statusLine" }) else { return data }
        var edited = bytes
        if members.count == 1 {
            edited.removeSubrange((open + 1)..<close)
        } else if index < members.count - 1 {
            // Through the comma, up to the next key.
            edited.removeSubrange(members[index].start..<members[index + 1].start)
        } else {
            // Last entry: take the comma before it too.
            edited.removeSubrange(members[index - 1].valueEnd..<members[index].valueEnd)
        }
        var expected = root
        expected.removeValue(forKey: "statusLine")
        return try verified(edited, equals: expected)
    }

    // MARK: - Helpers

    /// nil for a missing or empty file; throws for anything that isn't a JSON object.
    private static func parse(_ data: Data?) throws -> [String: Any]? {
        guard let data = data,
              !data.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EditError.notJSONObject
        }
        return root
    }

    /// Locates the top-level members, and refuses a file where `statusLine` or
    /// its `command` is ambiguous.
    private static func scan(_ data: Data) throws -> (bytes: [UInt8], open: Int, members: [Member], close: Int) {
        let bytes = [UInt8](data)
        guard let open = topLevelOpen(bytes), let (members, close) = Self.members(bytes, objectAt: open) else {
            throw EditError.notJSONObject
        }
        let statusLines = members.filter { $0.key == "statusLine" }
        guard statusLines.count <= 1 else { throw EditError.duplicateKeys }
        if let statusLine = statusLines.first,
           let (inner, _) = Self.members(bytes, objectAt: statusLine.valueStart),
           inner.filter({ $0.key == "command" }).count > 1 {
            throw EditError.duplicateKeys
        }
        return (bytes, open, members, close)
    }

    private static func verified(_ bytes: [UInt8], equals expected: [String: Any]) throws -> Data {
        let data = Data(bytes)
        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              NSDictionary(dictionary: result).isEqual(to: expected) else {
            throw EditError.verificationFailed
        }
        return data
    }

    private static func freshStatusLine(_ command: String, indent: String) -> String {
        let inner = indent + indent
        return "{\n\(inner)\"type\": \"command\",\n\(inner)\"command\": \(String(decoding: jsonString(command), as: UTF8.self))\n\(indent)}"
    }

    private static func jsonString(_ s: String) -> [UInt8] {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return [UInt8](data ?? Data("\"\"".utf8))
    }

    /// The whitespace the file uses in front of its top-level keys.
    private static func memberIndent(_ b: [UInt8], members: [Member]) -> String {
        guard let first = members.first else { return "  " }
        var i = first.start
        while i > 0, b[i - 1] == 0x20 || b[i - 1] == 0x09 { i -= 1 }
        guard i > 0, b[i - 1] == 0x0A, i < first.start else { return "  " }
        return String(decoding: b[i..<first.start], as: UTF8.self)
    }

    // MARK: - Minimal JSON scanner
    //
    // Only ever runs on text JSONSerialization has already accepted, so it
    // locates things; it doesn't validate. Every index is still bounds-checked.

    private struct Member {
        let key: String
        let start: Int        // opening quote of the key
        let valueStart: Int
        let valueEnd: Int     // one past the value's last byte
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    private static func skipSpace(_ b: [UInt8], _ i: Int) -> Int {
        var i = i
        while i < b.count, isSpace(b[i]) { i += 1 }
        return i
    }

    private static func topLevelOpen(_ b: [UInt8]) -> Int? {
        let i = skipSpace(b, 0)
        return i < b.count && b[i] == UInt8(ascii: "{") ? i : nil
    }

    /// `i` is at an opening quote; returns the index one past the closing quote.
    private static func stringEnd(_ b: [UInt8], _ i: Int) -> Int? {
        var j = i + 1
        while j < b.count {
            if b[j] == UInt8(ascii: "\\") { j += 2; continue }
            if b[j] == UInt8(ascii: "\"") { return j + 1 }
            j += 1
        }
        return nil
    }

    private static func valueEnd(_ b: [UInt8], _ i: Int) -> Int? {
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "\""):
            return stringEnd(b, i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var j = i
            while j < b.count {
                switch b[j] {
                case UInt8(ascii: "\""):
                    guard let end = stringEnd(b, j) else { return nil }
                    j = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return j + 1 }
                default:
                    break
                }
                j += 1
            }
            return nil
        default:
            var j = i
            while j < b.count, !isSpace(b[j]),
                  b[j] != UInt8(ascii: ","), b[j] != UInt8(ascii: "}"), b[j] != UInt8(ascii: "]") { j += 1 }
            return j
        }
    }

    /// The members of the object whose `{` is at `open`, plus the index of its `}`.
    private static func members(_ b: [UInt8], objectAt open: Int) -> (members: [Member], close: Int)? {
        guard open < b.count, b[open] == UInt8(ascii: "{") else { return nil }
        var out: [Member] = []
        var i = skipSpace(b, open + 1)
        guard i < b.count else { return nil }
        if b[i] == UInt8(ascii: "}") { return (out, i) }
        while true {
            guard i < b.count, b[i] == UInt8(ascii: "\""), let keyEnd = stringEnd(b, i),
                  let key = (try? JSONSerialization.jsonObject(with: Data(b[i..<keyEnd]), options: .fragmentsAllowed)) as? String
            else { return nil }
            var j = skipSpace(b, keyEnd)
            guard j < b.count, b[j] == UInt8(ascii: ":") else { return nil }
            j = skipSpace(b, j + 1)
            guard let end = valueEnd(b, j) else { return nil }
            out.append(Member(key: key, start: i, valueStart: j, valueEnd: end))
            j = skipSpace(b, end)
            guard j < b.count else { return nil }
            if b[j] == UInt8(ascii: ",") { i = skipSpace(b, j + 1); continue }
            if b[j] == UInt8(ascii: "}") { return (out, j) }
            return nil
        }
    }
}
