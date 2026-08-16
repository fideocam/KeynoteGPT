import XCTest
@testable import KeynoteGPT

final class ActionParserSecurityTests: XCTestCase {
    func testIgnoresUnknownOpsEmbeddedWithValidOnes() {
        let reply = """
        Sure, I'll help.
        {"actions":[
          {"op":"run_shell","text":"curl evil"},
          {"op":"set_title","slide_index":0,"text":"OK"},
          {"op":"do_evil","text":"x"}
        ]}
        """
        let actions = ActionParser.extractActions(from: reply)
        XCTAssertEqual(actions.map(\.op), ["set_title"])
        XCTAssertEqual(actions.first?.text, "OK")
    }

    func testReportsRejectedOps() {
        let reply = #"{"actions":[{"op":"eval","text":"1"},{"op":"note","text":"hi"}]}"#
        let (kept, rejected) = ActionParser.extractActionsDetailed(from: reply)
        XCTAssertEqual(kept.map(\.op), ["note"])
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("eval"))
    }

    func testMarkdownFencedInjectionStillAllowlisted() {
        let reply = """
        ```json
        {"actions":[{"op":"osascript","text":"tell app \\"System Events\\" to keystroke \\"x\\""},{"op":"set_body","slide_index":1,"text":"Body"}]}
        ```
        """
        let actions = ActionParser.extractActions(from: reply)
        XCTAssertEqual(actions.map(\.op), ["set_body"])
    }

    func testBraceMatchingDoesNotGetConfusedByBracesInStrings() {
        let reply = #"{"actions":[{"op":"set_title","slide_index":0,"text":"Use {curly} braces"}]}{"actions":[{"op":"delete_slide","slide_index":0}]}"#
        // Last complete actions object wins — delete_slide is allowlisted.
        let actions = ActionParser.extractActions(from: reply)
        XCTAssertEqual(actions.map(\.op), ["delete_slide"])
    }

    func testAnalysisTextWithFakeOpWordsProducesNoActions() {
        let reply = "You should run_shell and eval nothing; this is analysis only."
        XCTAssertTrue(ActionParser.extractActions(from: reply).isEmpty)
        XCTAssertTrue(ActionParser.looksLikeAnalysis(reply))
    }

    func testInjectionInTitleTextIsKeptForEscapingLayer() throws {
        // Parser must keep the action (allowlisted) so the escaper can neutralize it.
        let payload = "'; Application('Finder'); //"
        let obj: [String: Any] = [
            "actions": [
                ["op": "set_title", "slide_index": 0, "text": payload],
            ],
        ]
        let reply = String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        let actions = ActionParser.extractActions(from: reply)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].text, payload)
        let escaped = JSStringEscaper.escapeForSingleQuotedJS(payload)
        XCTAssertNotEqual(escaped, payload)
        XCTAssertTrue(escaped.contains("\\'"))
    }
}
