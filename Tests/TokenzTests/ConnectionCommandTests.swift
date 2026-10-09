import XCTest

/// Which status line commands count as this app. Getting this wrong in one
/// direction replaces a user's own status line; in the other it chains the
/// app to itself.
final class ConnectionCommandTests: XCTestCase {
    func testOurOwnCommandsAreRecognized() {
        let ours = [
            "'/Applications/Tokenz.app/Contents/MacOS/Tokenz' --statusline",
            "/Applications/Tokenz.app/Contents/MacOS/Tokenz --statusline",
            "/Applications/Tokenz.app/Contents/MacOS/Tokenz  --statusline",
            "\"/Users/a b/Applications/Tokenz.app/Contents/MacOS/Tokenz\" --statusline",
            "'/Users/o'\\''b/Apps/Tokenz.app/Contents/MacOS/Tokenz' --statusline",
            "'/Users/x/Applications/Tokenz.app/Contents/MacOS/Tokenz' --statusline",
        ]
        for command in ours { XCTAssertTrue(ClaudeCodeConnection.isOurs(command), command) }
    }

    func testCommandsThatOnlyMentionUsAreTheUsers() {
        let theirs = [
            "'/Applications/Tokenz.app/Contents/MacOS/Tokenz' --statusline | cat",
            "'/Applications/Tokenz.app/Contents/MacOS/Tokenz' --statusline 2>/dev/null",
            "/Applications/Tokenz.app/Contents/MacOS/Tokenz --statusline --extra",
            "/Applications/Tokenz.app/Contents/MacOS/Tokenz--statusline",
            "~/bin/wrapper.sh",
            "'/Applications/Tokenz copy.app/Contents/MacOS/Tokenz' --statusline",
            "~/.claude/statusline.sh",
            "~/.claude/statusline.sh; ~/bin/git-prompt.sh",
            "~/bin/wrap.sh /Applications/Tokenz.app/Contents/MacOS/Tokenz --statusline",
            "~/bin/mine.sh --theme dark # was ~/.claude/statusline.sh",
            "$(evil)/Tokenz.app/Contents/MacOS/Tokenz --statusline",
            "PATH=/evil:/Tokenz.app/Contents/MacOS/Tokenz --statusline",
            "X=/Applications/Tokenz.app/Contents/MacOS/Tokenz --statusline",
            "",
        ]
        for command in theirs { XCTAssertFalse(ClaudeCodeConnection.isOurs(command), command) }
    }

    func testBinaryPathIsExtractedWhateverTheQuoting() {
        let path = "/Applications/Tokenz.app/Contents/MacOS/Tokenz"
        XCTAssertEqual(ClaudeCodeConnection.binaryPath(in: "'\(path)' --statusline"), path)
        XCTAssertEqual(ClaudeCodeConnection.binaryPath(in: "\(path) --statusline"), path)
        XCTAssertEqual(ClaudeCodeConnection.binaryPath(in: "  \"\(path)\"\t--statusline\n"), path)
        XCTAssertNil(ClaudeCodeConnection.binaryPath(in: "~/.claude/statusline.sh"))
    }
}
