import XCTest
@testable import KeynoteGPT

final class JSStringEscaperSecurityTests: XCTestCase {
    func testClassicQuoteBreakoutDoesNotEscapeLiteral() {
        let payload = "'; Application('Finder').includeStandardAdditions = true; //"
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertEqual(roundTripViaJXA(escaped), payload)
        XCTAssertFalse(escaped.contains(payload))
        XCTAssertTrue(escaped.contains("\\'"))
    }

    func testBackslashThenQuoteDoesNotBreakOut() {
        let payload = "\\'; evil(); //"
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertEqual(roundTripViaJXA(escaped), payload)
    }

    func testUnicodeLineSeparatorCannotTerminateString() {
        let payload = "hello\u{2028}Application('Calculator');"
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertTrue(escaped.contains("\\u2028"))
        XCTAssertEqual(roundTripViaJXA(escaped), payload)
    }

    func testUnicodeParagraphSeparatorCannotTerminateString() {
        let payload = "hello\u{2029}quit();"
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertTrue(escaped.contains("\\u2029"))
        XCTAssertEqual(roundTripViaJXA(escaped), payload)
    }

    func testNewlinesAndTabsRoundTrip() {
        let payload = "line1\nline2\r\n\tend"
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertEqual(roundTripViaJXA(escaped), payload)
    }

    func testNullByteIsEscapedAndRejectedByValidator() {
        let payload = "ok\0bad"
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertTrue(escaped.contains("\\0"))
        XCTAssertTrue(JSStringEscaper.containsDisallowedControlCharacters(payload))
        XCTAssertNil(JSStringEscaper.validatedField(payload))
    }

    func testOversizedFieldRejected() {
        let huge = String(repeating: "A", count: JSStringEscaper.maxFieldLength + 1)
        XCTAssertNil(JSStringEscaper.validatedField(huge))
        XCTAssertNotNil(JSStringEscaper.validatedField(String(repeating: "B", count: 10)))
    }

    func testNestedQuotesAndScriptishPayloadRoundTrip() {
        let payload = "It's a \"test\" with `backticks` and </script>"
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertEqual(roundTripViaJXA(escaped), payload)
    }

    /// Evaluate `'escaped'` in the real JXA engine and return the string value.
    private func roundTripViaJXA(_ escaped: String) -> String? {
        let source = "(() => JSON.stringify('\(escaped)'))()"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            XCTFail("Failed to spawn osascript: \(error)")
            return nil
        }
        process.waitUntilExit()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "JXA failed: \(err)\nescaped=\(escaped)")
        guard let data = out.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data)
        else {
            XCTFail("Unexpected JXA output: \(out)")
            return nil
        }
        return value
    }
}
