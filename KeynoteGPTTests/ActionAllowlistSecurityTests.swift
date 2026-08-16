import XCTest
@testable import KeynoteGPT

final class ActionAllowlistSecurityTests: XCTestCase {
    func testUnknownOpsAreBlocked() {
        let actions = [
            decode(#"{"op":"run_shell","text":"rm -rf /"}"#)!,
            decode(#"{"op":"eval","text":"1+1"}"#)!,
            decode(#"{"op":"osascript","text":"tell app \"Finder\" to quit"}"#)!,
            decode(#"{"op":"set_title","slide_index":0,"text":"Safe"}"#)!,
        ]
        let (kept, rejected) = ActionAllowlist.sanitize(actions)
        XCTAssertEqual(kept.map(\.op), ["set_title"])
        XCTAssertEqual(rejected.count, 3)
        XCTAssertTrue(rejected.allSatisfy { $0.contains("blocked unknown op") })
    }

    func testPrototypePollutionStyleKeysDoNotCreateExtraOps() throws {
        let json = """
        {"actions":[{"op":"set_title","slide_index":0,"text":"Hi","__proto__":{"op":"delete_slide"}}]}
        """
        let batch = try JSONDecoder().decode(ActionBatch.self, from: Data(json.utf8))
        XCTAssertEqual(batch.actions.count, 1)
        XCTAssertEqual(batch.actions[0].op, "set_title")
        let (kept, rejected) = ActionAllowlist.sanitize(batch.actions)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testNulInTextIsRejected() {
        let action = decode(#"{"op":"set_body","slide_index":0,"text":"ok\u0000hack"}"#)!
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].contains("NUL"))
    }

    func testOversizedTextIsRejected() throws {
        let text = String(repeating: "x", count: JSStringEscaper.maxFieldLength + 50)
        let obj: [String: Any] = [
            "op": "set_title",
            "slide_index": 0,
            "text": text,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let action = try JSONDecoder().decode(KeynoteAction.self, from: data)
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(rejected[0].contains("exceeds"))
    }

    func testUnsupportedShapeIsRejected() {
        let action = decode(#"{"op":"add_shape","slide_index":0,"shape":"malware_poly"}"#)!
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(rejected[0].contains("unsupported shape"))
    }

    func testUnsupportedPositionNameIsRejected() {
        let action = decode(#"{"op":"add_slide","position":"'; Application('Finder'); //"}"#)!
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(rejected[0].contains("unsupported position"))
    }

    func testAllowedPositionsPass() {
        for position in ["end", "beginning", "after_current"] {
            let action = decode("{\"op\":\"add_slide\",\"position\":\"\(position)\"}")!
            let (kept, rejected) = ActionAllowlist.sanitize([action])
            XCTAssertEqual(kept.count, 1, position)
            XCTAssertTrue(rejected.isEmpty, position)
        }
    }

    func testAllowlistMatchesDocumentedOps() {
        let expected: Set<String> = [
            "note", "add_slide", "add_content_slide", "add_labeled_shape", "add_labeled_boxes",
            "add_color_table",
            "delete_slide", "duplicate_slide",
            "set_title", "set_body", "set_presenter_notes", "add_text_box",
            "set_text_item", "add_shape", "set_slide_skipped", "select_slide",
            "create_presentation",
            "set_opacity", "set_rotation", "set_text_style",
            "move_element", "resize_element", "delete_element",
            "add_image", "set_transition", "export_presentation",
        ]
        XCTAssertEqual(ActionAllowlist.allowedOps, expected)
    }

    func testAddImageRequiresAbsolutePath() {
        let relative = decode(#"{"op":"add_image","slide_index":0,"filepath":"logo.png"}"#)!
        let (keptRel, rejectedRel) = ActionAllowlist.sanitize([relative])
        XCTAssertTrue(keptRel.isEmpty)
        XCTAssertTrue(rejectedRel[0].contains("filepath"))

        let absolute = decode(#"{"op":"add_image","slide_index":0,"filepath":"/tmp/logo.png"}"#)!
        let (keptAbs, rejectedAbs) = ActionAllowlist.sanitize([absolute])
        XCTAssertEqual(keptAbs.count, 1)
        XCTAssertTrue(rejectedAbs.isEmpty)
    }

    func testOpacityOutOfRangeRejected() {
        let action = decode(#"{"op":"set_opacity","slide_index":0,"element_type":"shape","item_index":0,"opacity":150}"#)!
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(rejected[0].contains("opacity"))
    }

    func testLabeledBoxesRequiresLabels() {
        let action = decode(#"{"op":"add_labeled_boxes","title":"Dwarfs"}"#)!
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(rejected[0].contains("labels"))
    }

    func testLabeledBoxesAcceptsValidLabels() {
        let action = decode(#"{"op":"add_labeled_boxes","title":"Dwarfs","labels":["Doc","Grumpy"],"shape":"rounded_rectangle"}"#)!
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testTooManyLabelsRejected() {
        let labels = (0..<50).map { "Item\($0)" }
        let obj: [String: Any] = ["op": "add_labeled_boxes", "labels": labels]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let action = try! JSONDecoder().decode(KeynoteAction.self, from: data)
        let (kept, rejected) = ActionAllowlist.sanitize([action])
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(rejected[0].contains("labels exceeds"))
    }

    private func decode(_ json: String) -> KeynoteAction? {
        try? JSONDecoder().decode(KeynoteAction.self, from: Data(json.utf8))
    }
}
