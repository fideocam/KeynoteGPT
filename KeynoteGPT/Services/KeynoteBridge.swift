import Foundation

enum KeynoteBridgeError: LocalizedError {
    case scriptFailed(String)
    case notInstalled
    case noDocument

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return message
        case .notInstalled:
            return "Keynote does not appear to be installed or running."
        case .noDocument:
            return "No Keynote document is open."
        }
    }
}

/// Drives Keynote through JXA (`osascript -l JavaScript`).
actor KeynoteBridge {
    func isKeynoteRunning() async throws -> Bool {
        let js = #"""
        (() => {
          const se = Application('System Events');
          return se.processes.whose({ name: 'Keynote' }).length > 0;
        })()
        """#
        let out = try runJXA(js).trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "true"
    }

    func presentationDigest(maxSlides: Int = 40) async throws -> String {
        let mastersJSON: String
        do {
            let names = try listMasterSlideNames()
            let data = try JSONSerialization.data(withJSONObject: names)
            mastersJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            mastersJSON = "[]"
        }

        let js = #"""
        (() => {
          const kn = Application('Keynote');
          if (!kn.running()) {
            return JSON.stringify({ error: 'Keynote is not running.' });
          }
          kn.includeStandardAdditions = true;
          const docs = kn.documents;
          if (docs.length === 0) {
            return JSON.stringify({ error: 'No Keynote document is open.' });
          }
          const doc = docs[0];
          const slides = doc.slides;
          const maxSlides = \#(maxSlides);
          const count = Math.min(slides.length, maxSlides);
          const slideSummaries = [];
          for (let i = 0; i < count; i++) {
            const slide = slides[i];
            let title = '';
            let body = '';
            let notes = '';
            try { title = String(slide.defaultTitleItem.objectText() || ''); } catch (e) {}
            try { body = String(slide.defaultBodyItem.objectText() || ''); } catch (e) {}
            try { notes = String(slide.presenterNotes() || ''); } catch (e) {}
            const textItems = [];
            try {
              const items = slide.textItems;
              const n = Math.min(items.length, 12);
              for (let t = 0; t < n; t++) {
                let tx = '';
                try { tx = String(items[t].objectText() || ''); } catch (e) {}
                textItems.push({ index: t, text: tx.slice(0, 500) });
              }
            } catch (e) {}
            let master = '';
            try { master = String(slide.baseSlide.name() || ''); } catch (e) {}
            slideSummaries.push({
              index: i,
              skipped: !!(slide.skipped && slide.skipped()),
              master,
              title: title.slice(0, 300),
              body: body.slice(0, 1200),
              presenter_notes: notes.slice(0, 800),
              text_items: textItems
            });
          }
          let theme = '';
          try { theme = String(doc.documentTheme.name() || ''); } catch (e) {}
          let current = 0;
          try { current = doc.currentSlide.index() - 1; } catch (e) {}
          return JSON.stringify({
            name: String(doc.name()),
            theme,
            width: doc.width(),
            height: doc.height(),
            slide_count: slides.length,
            current_slide_index: current,
            master_layouts: \#(mastersJSON),
            truncated: slides.length > maxSlides,
            slides: slideSummaries
          }, null, 2);
        })()
        """#
        return try runJXA(js)
    }

    func apply(_ action: KeynoteAction, lastSlideHint: Int?) async throws -> (ActionResult, Int?) {
        var hint = lastSlideHint
        if !ActionAllowlist.isAllowed(action.op) {
            return (ActionResult(op: action.op, success: false, detail: "unknown op ignored"), hint)
        }
        if let reason = ActionAllowlist.rejectionReason(for: action) {
            return (ActionResult(op: action.op, success: false, detail: "rejected: \(reason)"), hint)
        }
        switch action.op {
        case "note":
            return (ActionResult(op: action.op, success: true, detail: action.text ?? ""), hint)
        case "create_presentation":
            let theme = escapeJS(action.theme ?? "")
            let width = action.width ?? 1920
            let height = action.height ?? 1080
            let js: String
            if theme.isEmpty {
                js = """
                (() => {
                  const kn = Application('Keynote');
                  kn.activate();
                  const doc = kn.Document({ width: \(width), height: \(height) });
                  kn.documents.push(doc);
                  return 'created';
                })()
                """
            } else {
                js = """
                (() => {
                  const kn = Application('Keynote');
                  kn.activate();
                  const theme = kn.themes.whose({ name: '\(theme)' })[0];
                  const props = { width: \(width), height: \(height) };
                  if (theme) props.documentTheme = theme;
                  const doc = kn.Document(props);
                  kn.documents.push(doc);
                  return 'created';
                })()
                """
            }
            let detail = try runJXA(js)
            hint = 0
            return (ActionResult(op: action.op, success: true, detail: detail), hint)

        case "add_slide":
            do {
                let idx = try addSlideAppleScript(
                    layout: action.layout,
                    position: action.position?.description ?? "end"
                )
                hint = idx
                return (ActionResult(op: action.op, success: true, detail: "slide \(idx)"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "add_content_slide":
            do {
                let title = action.title ?? action.text ?? ""
                let body = action.body ?? ""
                let layout = action.layout
                    ?? preferredLayout(forTitle: title, body: body)
                let idx = try addContentSlideAppleScript(
                    layout: layout,
                    title: title,
                    body: body,
                    position: action.position?.description ?? "end"
                )
                hint = idx
                return (ActionResult(op: action.op, success: true, detail: "slide \(idx) with content"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "delete_slide":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let js = """
            (() => {
              const kn = Application('Keynote');
              const doc = kn.documents[0];
              if (!doc) throw new Error('No Keynote document is open.');
              if (\(index) < 0 || \(index) >= doc.slides.length) throw new Error('slide_index out of range');
              doc.slides[\(index)].delete();
              return 'deleted';
            })()
            """
            let detail = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: detail), hint)

        case "duplicate_slide":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let js = """
            (() => {
              const kn = Application('Keynote');
              const doc = kn.documents[0];
              if (!doc) throw new Error('No Keynote document is open.');
              doc.slides[\(index)].duplicate();
              return String(doc.slides.length - 1);
            })()
            """
            let detail = try runJXA(js)
            if let idx = Int(detail.trimmingCharacters(in: .whitespacesAndNewlines)) {
                hint = idx
            }
            return (ActionResult(op: action.op, success: true, detail: "slide \(detail)"), hint)

        case "set_title":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let text = action.text ?? action.title ?? ""
                try setSlideText(slideIndex: index, role: .title, text: text)
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) title"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "set_body":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let text = action.text ?? action.body ?? ""
                try setSlideText(slideIndex: index, role: .body, text: text)
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) body"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "set_presenter_notes":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let text = escapeJS(action.text ?? "")
            let js = """
            (() => {
              const kn = Application('Keynote');
              kn.documents[0].slides[\(index)].presenterNotes = '\(text)';
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: "slide \(index) notes"), hint)

        case "add_text_box":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let text = escapeJS(action.text ?? "")
            let x = action.x ?? 100
            let y = action.y ?? 100
            let w = action.width ?? 400
            let h = action.height ?? 80
            let js = """
            (() => {
              const kn = Application('Keynote');
              const slide = kn.documents[0].slides[\(index)];
              const box = kn.TextItem({
                objectText: '\(text)',
                position: { x: \(x), y: \(y) },
                width: \(w),
                height: \(h)
              });
              slide.textItems.push(box);
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: "slide \(index) text box"), hint)

        case "set_text_item":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let item = action.itemIndex ?? 0
            let text = escapeJS(action.text ?? "")
            let js = """
            (() => {
              const kn = Application('Keynote');
              const slide = kn.documents[0].slides[\(index)];
              slide.textItems[\(item)].objectText = '\(text)';
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: "slide \(index) text_item \(item)"), hint)

        case "add_shape":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                try addLabeledShape(
                    slideIndex: index,
                    shape: action.shape,
                    text: action.text ?? "",
                    x: action.x ?? 80,
                    y: action.y ?? 80,
                    width: action.width ?? 200,
                    height: action.height ?? 120
                )
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) shape"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "add_labeled_shape":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let label = action.text ?? action.title ?? ""
                try addLabeledShape(
                    slideIndex: index,
                    shape: action.shape ?? "rounded_rectangle",
                    text: label,
                    x: action.x ?? 80,
                    y: action.y ?? 80,
                    width: action.width ?? 220,
                    height: action.height ?? 110
                )
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) labeled shape"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "add_labeled_boxes":
            do {
                let labels = action.labels ?? []
                let index: Int
                if action.title != nil || (action.slideIndex == nil && hint == nil) {
                    let layout = action.layout ?? "Title Only"
                    index = try addSlideAppleScript(
                        layout: layout,
                        position: action.position?.description ?? "end"
                    )
                    hint = index
                    if let title = action.title, !title.isEmpty {
                        try setSlideText(slideIndex: index, role: .title, text: title)
                    }
                } else {
                    index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                }
                let rects = BoxLayout.grid(
                    count: labels.count,
                    columns: action.columns,
                    slideWidth: action.width ?? 1920,
                    slideHeight: action.height ?? 1080
                )
                for (label, rect) in zip(labels, rects) {
                    try addLabeledShape(
                        slideIndex: index,
                        shape: action.shape ?? "rounded_rectangle",
                        text: label,
                        x: rect.x,
                        y: rect.y,
                        width: rect.width,
                        height: rect.height
                    )
                }
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) \(labels.count) boxes"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "set_slide_skipped":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let skipped = action.skipped ?? true
            let js = """
            (() => {
              const kn = Application('Keynote');
              kn.documents[0].slides[\(index)].skipped = \(skipped ? "true" : "false");
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: "slide \(index) skipped=\(skipped)"), hint)

        case "select_slide":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let js = """
            (() => {
              const kn = Application('Keynote');
              kn.activate();
              kn.documents[0].currentSlide = kn.documents[0].slides[\(index)];
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            hint = index
            return (ActionResult(op: action.op, success: true, detail: "selected \(index)"), hint)

        default:
            return (ActionResult(op: action.op, success: false, detail: "unknown op ignored"), hint)
        }
    }

    private func addLabeledShape(
        slideIndex: Int,
        shape: String?,
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) throws {
        let shapeType = BoxLayout.jxaShapeType(from: shape)
        let escaped = escapeJS(text)
        let js = """
        (() => {
          const kn = Application('Keynote');
          if (kn.documents.length === 0) throw new Error('No Keynote document is open.');
          const slide = kn.documents[0].slides[\(slideIndex)];
          const shape = kn.Shape({
            shapeType: '\(shapeType)',
            position: { x: \(x), y: \(y) },
            width: \(width),
            height: \(height),
            objectText: '\(escaped)'
          });
          slide.shapes.push(shape);
          try { shape.objectText = '\(escaped)'; } catch (e) {}
          return 'ok';
        })()
        """
        _ = try runJXA(js)
    }

    private enum TextRole {
        case title
        case body
    }

    private func preferredLayout(forTitle title: String, body: String) -> String {
        let blob = (title + " " + body).lowercased()
        if blob.contains("agenda") { return "Agenda" }
        if !body.isEmpty { return "Title & Bullets" }
        return "Title Only"
    }

    private func listMasterSlideNames() throws -> [String] {
        let out = try runAppleScript("""
        tell application "Keynote"
          if not (exists front document) then return ""
          tell front document
            set AppleScript's text item delimiters to "|||"
            set names to name of every master slide as text
            set AppleScript's text item delimiters to ""
            return names
          end tell
        end tell
        """)
        if out.isEmpty { return [] }
        return out.components(separatedBy: "|||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func addSlideAppleScript(layout: String?, position: String) throws -> Int {
        let layoutName = layout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pos = position.lowercased()
        let whereClause: String
        switch pos {
        case "beginning":
            whereClause = "at beginning of slides"
        default:
            whereClause = "at end of slides"
        }

        let script: String
        if layoutName.isEmpty {
            script = """
            tell application "Keynote"
              if not (exists front document) then error "No Keynote document is open."
              tell front document
                set newSlide to make new slide \(whereClause)
                return (slide number of newSlide) - 1
              end tell
            end tell
            """
        } else {
            script = """
            tell application "Keynote"
              if not (exists front document) then error "No Keynote document is open."
              tell front document
                try
                  set newSlide to make new slide \(whereClause) with properties {base slide:master slide "\(escapeAppleScript(layoutName))"}
                on error
                  set newSlide to make new slide \(whereClause)
                end try
                return (slide number of newSlide) - 1
              end tell
            end tell
            """
        }
        let out = try runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = Int(out) else {
            throw KeynoteBridgeError.scriptFailed("Could not parse new slide index: \(out)")
        }
        return idx
    }

    private func addContentSlideAppleScript(layout: String?, title: String, body: String, position: String) throws -> Int {
        let idx = try addSlideAppleScript(layout: layout, position: position)
        if !title.isEmpty {
            try setSlideText(slideIndex: idx, role: .title, text: title)
        }
        if !body.isEmpty {
            try setSlideText(slideIndex: idx, role: .body, text: body)
        }
        // Verify content landed; if body failed on layouts without body, fall back to text box.
        if !body.isEmpty {
            let verify = try runJXA("""
            (() => {
              const kn = Application('Keynote');
              const slide = kn.documents[0].slides[\(idx)];
              try { return String(slide.defaultBodyItem.objectText() || ''); } catch (e) { return ''; }
            })()
            """)
            if verify.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let escaped = escapeJS(body)
                _ = try runJXA("""
                (() => {
                  const kn = Application('Keynote');
                  const slide = kn.documents[0].slides[\(idx)];
                  const box = kn.TextItem({
                    objectText: '\(escaped)',
                    position: { x: 80, y: 220 },
                    width: 1600,
                    height: 600
                  });
                  slide.textItems.push(box);
                  return 'ok';
                })()
                """)
            }
        }
        return idx
    }

    private func setSlideText(slideIndex: Int, role: TextRole, text: String) throws {
        let escaped = escapeJS(text)
        let primary: String
        let fallbackIndex: Int
        switch role {
        case .title:
            primary = "defaultTitleItem"
            fallbackIndex = 0
        case .body:
            primary = "defaultBodyItem"
            fallbackIndex = 1
        }
        let js = """
        (() => {
          const kn = Application('Keynote');
          if (kn.documents.length === 0) throw new Error('No Keynote document is open.');
          const slide = kn.documents[0].slides[\(slideIndex)];
          const value = '\(escaped)';
          try {
            slide.\(primary).objectText = value;
            return 'ok-primary';
          } catch (e1) {
            try {
              if (slide.textItems.length > \(fallbackIndex)) {
                slide.textItems[\(fallbackIndex)].objectText = value;
                return 'ok-textitem';
              }
            } catch (e2) {}
            try {
              const box = kn.TextItem({
                objectText: value,
                position: { x: 80, y: \(role == .title ? 80 : 220) },
                width: 1600,
                height: \(role == .title ? 120 : 600)
              });
              slide.textItems.push(box);
              return 'ok-textbox';
            } catch (e3) {
              throw new Error('Could not set \(role == .title ? "title" : "body"): ' + e1);
            }
          }
        })()
        """
        _ = try runJXA(js)
    }

    private func resolveSlideIndex(_ raw: Int?, lastSlideHint: Int?) throws -> Int {
        // Models often omit slide_index after add_slide — use the last created/selected slide.
        let effective = raw ?? -1
        if effective == -1 {
            if let lastSlideHint { return lastSlideHint }
            let js = """
            (() => {
              const kn = Application('Keynote');
              if (kn.documents.length === 0) throw new Error('No Keynote document is open.');
              return String(kn.documents[0].slides.length - 1);
            })()
            """
            let out = try runJXA(js).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = Int(out), idx >= 0 else {
                throw KeynoteBridgeError.scriptFailed("Could not resolve last slide index")
            }
            return idx
        }
        return effective
    }

    private func escapeJS(_ value: String) -> String {
        JSStringEscaper.escapeForSingleQuotedJS(value)
    }

    private func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw KeynoteBridgeError.scriptFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            let message = err.isEmpty ? (out.isEmpty ? "AppleScript failed with status \(process.terminationStatus)" : out) : err
            throw KeynoteBridgeError.scriptFailed(message)
        }
        return out
    }

    @discardableResult
    private func runJXA(_ source: String) throws -> String {
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
            throw KeynoteBridgeError.scriptFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            let message = err.isEmpty ? (out.isEmpty ? "JXA failed with status \(process.terminationStatus)" : out) : err
            throw KeynoteBridgeError.scriptFailed(message)
        }
        return out
    }
}
