import XCTest

final class SettingsEditorTests: XCTestCase {
    private let command = "'/Applications/Tokenz.app/Contents/MacOS/Tokenz' --statusline"

    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testMissingOrBlankFileGetsAFreshEntry() throws {
        for input in [nil, data(""), data("  \n")] as [Data?] {
            let result = try SettingsEditor.settingStatusLineCommand(command, in: input)
            XCTAssertEqual(try SettingsEditor.statusLineCommand(in: result), command)
        }
    }

    func testEmptyObjectRoundTrips() throws {
        let added = try SettingsEditor.settingStatusLineCommand(command, in: data("{}"))
        XCTAssertEqual(try SettingsEditor.statusLineCommand(in: added), command)
        let removed = try SettingsEditor.removingStatusLine(in: added)
        XCTAssertEqual(text(removed).trimmingCharacters(in: .whitespacesAndNewlines), "{}")
    }

    func testAddingLeavesEveryOtherByteAlone() throws {
        let original = data("""
        {
            "a": "x \\"statusLine\\": {} , }",
            "nested": {"statusLine": {"command": "decoy"}, "arr": [1, {"k": "]}"}]},
            "n": -1.5e3, "t": true, "z": null,
            "uni": "caf\\u00e9 ✓"
        }
        """)
        let added = try SettingsEditor.settingStatusLineCommand(command, in: original)
        XCTAssertEqual(try SettingsEditor.statusLineCommand(in: added), command)
        XCTAssertTrue(text(added).hasPrefix(String(text(original).dropLast(2))))
        // Uses the file's own indentation.
        XCTAssertTrue(text(added).contains("\n    \"statusLine\": {\n        \"type\""))
        XCTAssertEqual(try SettingsEditor.removingStatusLine(in: added), original)
    }

    func testReplacingKeepsOtherStatusLineFieldsAndRestoresExactly() throws {
        let theirs = "~/.claude/my line.sh --x \"q\""
        let original = data("{\n  \"model\": \"opus\",\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"~/.claude/my line.sh --x \\\"q\\\"\",\n    \"padding\": 0\n  },\n  \"last\": 1\n}\n")
        XCTAssertEqual(try SettingsEditor.statusLineCommand(in: original), theirs)

        let replaced = try SettingsEditor.settingStatusLineCommand(command, in: original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: replaced) as? [String: Any])
        XCTAssertEqual((object["statusLine"] as? [String: Any])?["padding"] as? Int, 0)
        let changedLines = zip(text(replaced).split(separator: "\n"), text(original).split(separator: "\n"))
            .filter { $0 != $1 }
        XCTAssertEqual(changedLines.count, 1)

        XCTAssertEqual(try SettingsEditor.settingStatusLineCommand(theirs, in: replaced), original)
    }

    func testRemoving() throws {
        let middle = data("{\n  \"model\": \"opus\",\n  \"statusLine\": {\"type\": \"command\", \"command\": \"x\"},\n  \"last\": 1\n}\n")
        XCTAssertEqual(text(try SettingsEditor.removingStatusLine(in: middle)), "{\n  \"model\": \"opus\",\n  \"last\": 1\n}\n")
        let last = data("{\"a\":1,\"statusLine\":{\"type\":\"command\",\"command\":\"x\"}}")
        XCTAssertEqual(text(try SettingsEditor.removingStatusLine(in: last)), "{\"a\":1}")
        let absent = data("{\"a\":1}")
        XCTAssertEqual(try SettingsEditor.removingStatusLine(in: absent), absent)
    }

    func testCommandWithQuotesSurvives() throws {
        let quoted = "'/Users/o'\\''brien/Apps/Tokenz.app/Contents/MacOS/Tokenz' --statusline"
        let result = try SettingsEditor.settingStatusLineCommand(quoted, in: data("{\"a\": 1}"))
        XCTAssertEqual(try SettingsEditor.statusLineCommand(in: result), quoted)
    }

    func testNonObjectStatusLineIsReplaced() throws {
        let result = try SettingsEditor.settingStatusLineCommand(command, in: data("{\"statusLine\": \"nonsense\", \"b\": 2}"))
        XCTAssertEqual(try SettingsEditor.statusLineCommand(in: result), command)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["b"] as? Int, 2)
    }

    func testInvalidJSONIsRefused() {
        for bad in ["{ not json", "[1,2]", "{\"a\": 1,}", "// c\n{}", "\u{FEFF}{}"] {
            XCTAssertThrowsError(try SettingsEditor.settingStatusLineCommand(command, in: data(bad)), bad)
            XCTAssertThrowsError(try SettingsEditor.statusLineCommand(in: data(bad)), bad)
        }
    }

    func testDuplicateKeysAreRefused() {
        let duplicates = [
            "{\"statusLine\":{\"type\":\"command\",\"command\":\"A\",\"command\":\"B\"}}",
            "{\"statusLine\":{\"command\":\"A\"},\"x\":1,\"statusLine\":{\"command\":\"B\"}}",
            "{\"status\\u004cine\":{\"command\":\"A\"},\"statusLine\":{\"command\":\"B\"}}",
        ]
        for duplicate in duplicates {
            XCTAssertThrowsError(try SettingsEditor.statusLineCommand(in: data(duplicate)), duplicate)
            XCTAssertThrowsError(try SettingsEditor.settingStatusLineCommand(command, in: data(duplicate)), duplicate)
            XCTAssertThrowsError(try SettingsEditor.removingStatusLine(in: data(duplicate)), duplicate)
        }
        // A duplicate somewhere else is not ours to judge.
        XCTAssertNoThrow(try SettingsEditor.settingStatusLineCommand(command, in: data("{\"a\":{\"statusLine\":1,\"statusLine\":2}}")))
    }
}
