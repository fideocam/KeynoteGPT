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
            truncated: slides.length > maxSlides,
            slides: slideSummaries
          }, null, 2);
        })()
        """#
        return try runJXA(js)
    }

    func apply(_ action: KeynoteAction, lastSlideHint: Int?) async throws -> (ActionResult, Int?) {
        var hint = lastSlideHint
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
            let layout = escapeJS(action.layout ?? "")
            let positionName = action.position?.description ?? "end"
            let js = """
            (() => {
              const kn = Application('Keynote');
              if (kn.documents.length === 0) throw new Error('No Keynote document is open.');
              const doc = kn.documents[0];
              const props = {};
              const layoutName = '\(layout)';
              if (layoutName) {
                try {
                  const master = doc.masterSlides.whose({ name: layoutName })[0];
                  if (master) props.baseSlide = master;
                } catch (e) {}
              }
              const slide = kn.Slide(props);
              const positionName = '\(escapeJS(positionName))';
              if (positionName === 'beginning') {
                doc.slides.unshift(slide);
                return '0';
              }
              doc.slides.push(slide);
              return String(doc.slides.length - 1);
            })()
            """
            let detail = try runJXA(js)
            if let idx = Int(detail.trimmingCharacters(in: .whitespacesAndNewlines)) {
                hint = idx
            }
            return (ActionResult(op: action.op, success: true, detail: "slide \(detail)"), hint)

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
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let text = escapeJS(action.text ?? "")
            let js = """
            (() => {
              const kn = Application('Keynote');
              const slide = kn.documents[0].slides[\(index)];
              slide.defaultTitleItem.objectText = '\(text)';
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: "slide \(index) title"), hint)

        case "set_body":
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let text = escapeJS(action.text ?? "")
            let js = """
            (() => {
              const kn = Application('Keynote');
              const slide = kn.documents[0].slides[\(index)];
              slide.defaultBodyItem.objectText = '\(text)';
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: "slide \(index) body"), hint)

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
            let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
            let shape = (action.shape ?? "rectangle").lowercased()
            let x = action.x ?? 80
            let y = action.y ?? 80
            let w = action.width ?? 200
            let h = action.height ?? 120
            let shapeType: String
            switch shape {
            case "oval", "circle", "ellipse": shapeType = "oval"
            case "rounded_rectangle", "round_rect", "rounded": shapeType = "rounded rectangle"
            default: shapeType = "rectangle"
            }
            let js = """
            (() => {
              const kn = Application('Keynote');
              const slide = kn.documents[0].slides[\(index)];
              const shape = kn.Shape({
                shapeType: '\(shapeType)',
                position: { x: \(x), y: \(y) },
                width: \(w),
                height: \(h)
              });
              slide.shapes.push(shape);
              return 'ok';
            })()
            """
            _ = try runJXA(js)
            return (ActionResult(op: action.op, success: true, detail: "slide \(index) \(shapeType)"), hint)

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

    private func resolveSlideIndex(_ raw: Int?, lastSlideHint: Int?) throws -> Int {
        guard let raw else {
            throw KeynoteBridgeError.scriptFailed("slide_index is required")
        }
        if raw == -1 {
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
        return raw
    }

    private func escapeJS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
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
