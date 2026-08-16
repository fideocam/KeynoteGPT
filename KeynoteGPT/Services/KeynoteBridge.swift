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
            let shapeCount = 0, imageCount = 0, tableCount = 0, lineCount = 0;
            try { shapeCount = slide.shapes.length; } catch (e) {}
            try { imageCount = slide.images.length; } catch (e) {}
            try { tableCount = slide.tables.length; } catch (e) {}
            try { lineCount = slide.lines.length; } catch (e) {}
            const shapeSummaries = [];
            try {
              const n = Math.min(shapeCount, 16);
              for (let s = 0; s < n; s++) {
                let ot = '';
                let fill = '';
                try { ot = String(slide.shapes[s].objectText() || '').slice(0, 80); } catch (e) {}
                try { fill = String(slide.shapes[s].backgroundFillType()); } catch (e) {
                  try { fill = String(slide.shapes[s].backgroundFillType); } catch (e2) {}
                }
                shapeSummaries.push({ index: s, text: ot, fill_type: fill });
              }
            } catch (e) {}
            slideSummaries.push({
              index: i,
              skipped: !!(slide.skipped && slide.skipped()),
              master,
              title: title.slice(0, 300),
              body: body.slice(0, 1200),
              presenter_notes: notes.slice(0, 800),
              text_items: textItems,
              shape_count: shapeCount,
              image_count: imageCount,
              table_count: tableCount,
              line_count: lineCount,
              shapes: shapeSummaries
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
            scripting_notes: {
              shape_fill_color: "not_scriptable",
              shape_style_presets: "ui_only_best_effort",
              object_builds: "not_scriptable",
              table_cell_colors: "scriptable"
            },
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
                    height: action.height ?? 120,
                    styleIndex: 0
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
                    height: action.height ?? 110,
                    styleIndex: 0
                )
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) shape box"), hint)
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
                for (offset, (label, rect)) in zip(labels, rects).enumerated() {
                    try addLabeledShape(
                        slideIndex: index,
                        shape: action.shape ?? "rounded_rectangle",
                        text: label,
                        x: rect.x,
                        y: rect.y,
                        width: rect.width,
                        height: rect.height,
                        styleIndex: offset
                    )
                }
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) \(labels.count) shape boxes"), hint)
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

        case "set_opacity":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let item = action.itemIndex ?? 0
                let opacity = action.opacity ?? 100
                let element = (action.elementType ?? "shape").lowercased()
                try setElementProperty(slideIndex: index, elementType: element, itemIndex: item, opacity: opacity, rotation: nil)
                return (ActionResult(op: action.op, success: true, detail: "\(element)[\(item)] opacity=\(opacity)"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "set_rotation":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let item = action.itemIndex ?? 0
                let rotation = action.rotation ?? 0
                let element = (action.elementType ?? "shape").lowercased()
                try setElementProperty(slideIndex: index, elementType: element, itemIndex: item, opacity: nil, rotation: rotation)
                return (ActionResult(op: action.op, success: true, detail: "\(element)[\(item)] rotation=\(rotation)"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "set_text_style":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                try setTextStyle(action: action, slideIndex: index)
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) text style"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "move_element":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let item = action.itemIndex ?? 0
                let element = (action.elementType ?? "shape").lowercased()
                let x = Int(action.x ?? 80)
                let y = Int(action.y ?? 80)
                try setElementFrame(slideIndex: index, elementType: element, itemIndex: item, x: x, y: y, width: nil, height: nil)
                return (ActionResult(op: action.op, success: true, detail: "\(element)[\(item)] -> (\(x),\(y))"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "resize_element":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let item = action.itemIndex ?? 0
                let element = (action.elementType ?? "shape").lowercased()
                let w = Int(action.width ?? 200)
                let h = Int(action.height ?? 120)
                try setElementFrame(slideIndex: index, elementType: element, itemIndex: item, x: nil, y: nil, width: w, height: h)
                return (ActionResult(op: action.op, success: true, detail: "\(element)[\(item)] size \(w)x\(h)"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "delete_element":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let item = action.itemIndex ?? 0
                let element = (action.elementType ?? "shape").lowercased()
                try deleteElement(slideIndex: index, elementType: element, itemIndex: item)
                return (ActionResult(op: action.op, success: true, detail: "deleted \(element)[\(item)]"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "add_image":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                guard let path = action.filepath else {
                    return (ActionResult(op: action.op, success: false, detail: "filepath required"), hint)
                }
                try addImage(slideIndex: index, filepath: path, x: action.x ?? 100, y: action.y ?? 100, width: action.width, height: action.height)
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) image"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "add_color_table":
            do {
                let labels = action.labels ?? []
                let index: Int
                if action.title != nil || (action.slideIndex == nil && hint == nil) {
                    index = try addSlideAppleScript(layout: action.layout ?? "Title Only", position: action.position?.description ?? "end")
                    hint = index
                    if let title = action.title, !title.isEmpty {
                        try setSlideText(slideIndex: index, role: .title, text: title)
                    }
                } else {
                    index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                }
                let columns = max(2, action.columns ?? BoxLayout.preferredColumns(for: labels.count))
                try addColorTable(slideIndex: index, labels: labels, columns: columns, x: action.x ?? 80, y: action.y ?? 200, width: action.width ?? 1760, height: action.height ?? 560)
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) color table \(labels.count) cells"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "set_transition":
            do {
                let index = try resolveSlideIndex(action.slideIndex, lastSlideHint: hint)
                let name = (action.transition ?? "dissolve").lowercased().replacingOccurrences(of: " ", with: "_")
                try setTransition(slideIndex: index, transition: name)
                return (ActionResult(op: action.op, success: true, detail: "slide \(index) transition=\(name)"), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

        case "export_presentation":
            do {
                let format = (action.format ?? "pdf").lowercased()
                let path = try exportPresentation(format: format, filepath: action.filepath)
                return (ActionResult(op: action.op, success: true, detail: path), hint)
            } catch {
                return (ActionResult(op: action.op, success: false, detail: error.localizedDescription), hint)
            }

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
        height: Double,
        styleIndex: Int
    ) throws {
        let shapeType = BoxLayout.jxaShapeType(from: shape)
        let escaped = escapeJS(text)
        let fill = ThemePalette.color(at: styleIndex)
        // Text color is scriptable; shape *fill* is not exposed by Keynote's dictionary.
        let tr = Double(fill.contrastingText.r) / 65535.0
        let tg = Double(fill.contrastingText.g) / 65535.0
        let tb = Double(fill.contrastingText.b) / 65535.0
        // Prefer readable label color on unknown fills: use the accent itself for text
        // when the theme default fill is dark/black.
        let accentR = Double(fill.r) / 65535.0
        let accentG = Double(fill.g) / 65535.0
        let accentB = Double(fill.b) / 65535.0

        let js = """
        (() => {
          const kn = Application('Keynote');
          if (kn.documents.length === 0) throw new Error('No Keynote document is open.');
          const doc = kn.documents[0];
          try { doc.currentSlide = doc.slides[\(slideIndex)]; } catch (e) {}
          const slide = doc.slides[\(slideIndex)];
          const shape = kn.Shape({
            shapeType: '\(shapeType)',
            position: { x: \(x), y: \(y) },
            width: \(width),
            height: \(height),
            objectText: '\(escaped)'
          });
          slide.shapes.push(shape);
          try { shape.objectText = '\(escaped)'; } catch (e) {}
          try { shape.objectText.color = [\(accentR), \(accentG), \(accentB)]; } catch (e) {
            try { shape.objectText.color = [\(tr), \(tg), \(tb)]; } catch (e2) {}
          }
          return 'ok';
        })()
        """
        _ = try runJXA(js)

        // Apply a distinct theme Shape Style (fill) via Accessibility UI after selecting the new shape.
        try? applyThemeShapeStyleToLastShape(styleIndex: styleIndex)
    }

    /// Selects the last shape on the current slide and clicks a Format style well.
    /// Requires Accessibility permission for KeynoteGPT. Fails soft if UI layout differs.
    private func applyThemeShapeStyleToLastShape(styleIndex: Int) throws {
        let well = (styleIndex % 8) + 1
        let script = """
        tell application "Keynote" to activate
        delay 0.08
        tell application "System Events"
          tell process "Keynote"
            set frontmost to true
            -- Move focus to slide canvas then to last object (Keynote: Option+Shift+], varies by version)
            try
              keystroke "]" using {option down, shift down}
            end try
            delay 0.05
            try
              click menu item "Show Format" of menu "View" of menu bar 1
            end try
            delay 0.08
            try
              click radio button "Style" of tab group 1 of scroll area 1 of splitter group 1 of window 1
            end try
            try
              click radio button "Style" of radio group 1 of scroll area 1 of splitter group 1 of window 1
            end try
            delay 0.05
            set applied to false
            try
              tell scroll area 1 of splitter group 1 of window 1
                if (count of radio buttons) ≥ \(well) then
                  click radio button \(well)
                  set applied to true
                else if (count of buttons) ≥ \(well) then
                  click button \(well)
                  set applied to true
                end if
              end tell
            end try
            if applied is false then
              try
                tell radio group 1 of scroll area 1 of splitter group 1 of window 1
                  if (count of radio buttons) ≥ \(well) then
                    click radio button \(well)
                    set applied to true
                  end if
                end tell
              end try
            end if
            return applied as string
          end tell
        end tell
        """
        _ = try runAppleScript(script)
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

    private func appleCollectionName(for elementType: String) -> String {
        switch elementType.lowercased() {
        case "text_item", "textitem", "text": return "text item"
        case "image": return "image"
        case "table": return "table"
        default: return "shape"
        }
    }

    private func setElementProperty(slideIndex: Int, elementType: String, itemIndex: Int, opacity: Int?, rotation: Int?) throws {
        let coll = appleCollectionName(for: elementType)
        var lines: [String] = []
        if let opacity { lines.append("set opacity of target to \(opacity)") }
        if let rotation { lines.append("set rotation of target to \(rotation)") }
        guard !lines.isEmpty else { return }
        let script = """
        tell application "Keynote"
          tell front document
            tell slide \(slideIndex + 1)
              set target to \(coll) \(itemIndex + 1)
              \(lines.joined(separator: "\n              "))
            end tell
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func setElementFrame(slideIndex: Int, elementType: String, itemIndex: Int, x: Int?, y: Int?, width: Int?, height: Int?) throws {
        let coll = appleCollectionName(for: elementType)
        var lines: [String] = []
        if let x, let y { lines.append("set position of target to {\(x), \(y)}") }
        if let width { lines.append("set width of target to \(width)") }
        if let height { lines.append("set height of target to \(height)") }
        guard !lines.isEmpty else { return }
        let script = """
        tell application "Keynote"
          tell front document
            tell slide \(slideIndex + 1)
              set target to \(coll) \(itemIndex + 1)
              \(lines.joined(separator: "\n              "))
            end tell
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func deleteElement(slideIndex: Int, elementType: String, itemIndex: Int) throws {
        let coll = appleCollectionName(for: elementType)
        let script = """
        tell application "Keynote"
          tell front document
            tell slide \(slideIndex + 1)
              delete \(coll) \(itemIndex + 1)
            end tell
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func setTextStyle(action: KeynoteAction, slideIndex: Int) throws {
        let font = action.font.map(escapeAppleScript)
        let size = action.fontSize
        let colorTuple: String?
        if let color = action.color, color.count == 3 {
            // AppleScript color uses 0…65535
            colorTuple = "{\(color[0] * 257), \(color[1] * 257), \(color[2] * 257)}"
        } else {
            colorTuple = nil
        }
        let target: String
        let element = (action.elementType ?? "title").lowercased()
        switch element {
        case "body":
            target = "default body item"
        case "shape":
            target = "shape \((action.itemIndex ?? 0) + 1)"
        case "text_item", "text":
            target = "text item \((action.itemIndex ?? 0) + 1)"
        default:
            target = "default title item"
        }
        var lines: [String] = []
        if let font { lines.append("set font of object text of target to \"\(font)\"") }
        if let size { lines.append("set size of object text of target to \(size)") }
        if let colorTuple { lines.append("set color of object text of target to \(colorTuple)") }
        guard !lines.isEmpty else {
            throw KeynoteBridgeError.scriptFailed("set_text_style requires font, font_size, and/or color")
        }
        let script = """
        tell application "Keynote"
          tell front document
            tell slide \(slideIndex + 1)
              set target to \(target)
              \(lines.joined(separator: "\n              "))
            end tell
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func addImage(slideIndex: Int, filepath: String, x: Double, y: Double, width: Double?, height: Double?) throws {
        let expanded = (filepath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw KeynoteBridgeError.scriptFailed("Image file not found: \(expanded)")
        }
        let escaped = escapeAppleScript(expanded)
        var sizeLines = ""
        if let width { sizeLines += "\n              set width of img to \(Int(width))" }
        if let height { sizeLines += "\n              set height of img to \(Int(height))" }
        let script = """
        tell application "Keynote"
          tell front document
            tell slide \(slideIndex + 1)
              set img to make new image with properties {file:POSIX file "\(escaped)"}
              set position of img to {\(Int(x)), \(Int(y))}
              \(sizeLines)
            end tell
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func addColorTable(slideIndex: Int, labels: [String], columns: Int, x: Double, y: Double, width: Double, height: Double) throws {
        let cols = max(2, columns)
        let rows = max(1, Int(ceil(Double(max(labels.count, 1)) / Double(cols))))
        let palette = ThemePalette.presentationAccents
        let total = cols * rows
        var cellBlocks: [String] = []
        for i in 0..<total {
            let row = (i / cols) + 1
            let col = (i % cols) + 1
            let label = i < labels.count ? labels[i] : ""
            let fill = label.isEmpty ? ThemePalette.emptyCell : ThemePalette.color(at: i, from: palette)
            let text = label.isEmpty ? ThemePalette.RGB(r: 0, g: 0, b: 0) : fill.contrastingText
            cellBlocks.append("""
            set theCell to cell \(col) of row \(row) of t
            set background color of theCell to \(fill.appleScriptTuple)
            set value of theCell to "\(escapeAppleScript(label))"
            set text color of theCell to \(text.appleScriptTuple)
            """)
        }
        let script = """
        tell application "Keynote"
          tell front document
            tell slide \(slideIndex + 1)
              set t to make new table with properties {column count:\(cols), row count:\(rows)}
              try
                set header row count of t to 0
              end try
              try
                set header column count of t to 0
              end try
              try
                set footer row count of t to 0
              end try
              set position of t to {\(Int(x)), \(Int(y))}
              set width of t to \(Int(width))
              set height of t to \(Int(height))
              \(cellBlocks.joined(separator: "\n              "))
            end tell
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func setTransition(slideIndex: Int, transition: String) throws {
        let effect: String
        switch transition {
        case "none": effect = "no transition effect"
        case "magic_move": effect = "magic move"
        case "move_in": effect = "move in"
        case "fade_through_color": effect = "fade through color"
        case "fade_and_move": effect = "fade and move"
        default: effect = transition.replacingOccurrences(of: "_", with: " ")
        }
        let script = """
        tell application "Keynote"
          tell front document
            tell slide \(slideIndex + 1)
              set transition properties to {transition effect:\(effect), transition duration:0.5, transition delay:0, automatic transition:false}
            end tell
          end tell
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func exportPresentation(format: String, filepath: String?) throws -> String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        let dest: URL
        let exportAs: String
        switch format {
        case "png":
            dest = filepath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? downloads.appendingPathComponent("KeynoteGPT-\(stamp)")
            exportAs = "slide images"
        case "powerpoint":
            dest = filepath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? downloads.appendingPathComponent("KeynoteGPT-\(stamp).pptx")
            exportAs = "Microsoft PowerPoint"
        default:
            dest = filepath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? downloads.appendingPathComponent("KeynoteGPT-\(stamp).pdf")
            exportAs = "PDF"
        }
        let escaped = escapeAppleScript(dest.path)
        let script: String
        if format == "png" {
            script = """
            tell application "Keynote"
              export front document to POSIX file "\(escaped)" as slide images with properties {image format:PNG}
            end tell
            return "\(escaped)"
            """
        } else {
            script = """
            tell application "Keynote"
              export front document to POSIX file "\(escaped)" as \(exportAs)
            end tell
            return "\(escaped)"
            """
        }
        return try runAppleScript(script)
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
        try runOSA(source: source, language: nil)
    }

    @discardableResult
    private func runJXA(_ source: String) throws -> String {
        try runOSA(source: source, language: "JavaScript")
    }

    /// Runs osascript via a temp file (avoids `-e` length/escaping issues) and maps auth failures clearly.
    private func runOSA(source: String, language: String?) throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keynotegpt-\(UUID().uuidString).\(language == nil ? "applescript" : "js")")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try source.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            throw KeynoteBridgeError.scriptFailed("Could not write temporary script: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        if let language {
            process.arguments = ["-l", language, tempURL.path]
        } else {
            process.arguments = [tempURL.path]
        }
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
            let raw = err.isEmpty ? (out.isEmpty ? "osascript failed with status \(process.terminationStatus)" : out) : err
            throw KeynoteBridgeError.scriptFailed(Self.friendlyAutomationMessage(from: raw))
        }
        return out
    }

    private static func friendlyAutomationMessage(from raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("not authorised")
            || lowered.contains("not authorized")
            || lowered.contains("(-1743)")
            || (lowered.contains("execution error") && lowered.contains("apple event")) {
            return """
            KeynoteGPT is not allowed to control Keynote. Open System Settings → Privacy & Security → Automation, enable Keynote for KeynoteGPT, then quit and reopen KeynoteGPT. Also keep a Keynote document open. (\(raw))
            """
        }
        if lowered.contains("execution error") {
            return """
            Keynote scripting failed. Keep Keynote open with a document, and allow Automation (System Settings → Privacy & Security → Automation → KeynoteGPT → Keynote). Details: \(raw)
            """
        }
        return raw
    }
}
