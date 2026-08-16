# Keynote scripting gaps

KeynoteGPT drives Keynote through **AppleScript / JXA** (`osascript`). There is **no plugin SDK**. Capabilities are capped by Apple’s scripting dictionary (`sdef` for Keynote).

This document lists known gaps, what KeynoteGPT does instead, and what is fixed in-app where the dictionary allows it.

## Hard gaps (not exposed by Apple — cannot fix in-process)

| Gap | Impact | Workaround in KeynoteGPT |
|-----|--------|---------------------------|
| **Shape / text-item fill color** | `background fill type` is **read-only**. Cannot set RGB/gradient/image fill on shapes via scripting. | Real **shape** boxes still created. Optional best-effort **Accessibility UI** click of Format → Style wells (fragile; needs Accessibility permission). Text **color** *is* scriptable and is varied per box. |
| **Shape style presets API** | No “Shape Style” class or command. | Same UI best-effort as above. |
| **Selection API for canvas objects** | Cannot reliably `set selection to shape N`. | Limits reliable “format the shape I just made” UI scripting. |
| **Master / theme color palette readback** | Theme object only exposes `name` / `id`. No palette RGB list. | Built-in accent palette + harvest of **table cell** background colors when present. |
| **Build / animation editor** | Slide has `transition properties` only; object builds (appear, move, etc.) are not in the dictionary. | Not supported. |
| **Many Format inspector knobs** | Borders, shadows, corner radius, precise paragraph styles, columns, etc. | Not supported (except what rich text exposes: font / size / color). |
| **Groups** | `group` exists as a container element; grouping/ungrouping UX is poorly scripted. | Not supported. |
| **Charts styling** | `add chart` exists with legacy data params; modern chart formatting is limited. | Not a first-class KeynoteGPT action yet. |

## Soft gaps (awkward / version-fragile)

| Gap | Notes | Mitigation |
|-----|-------|------------|
| **JXA `masterSlides` / `baseSlide.name`** | Often throws “Can't convert types.” | Use **AppleScript** for layout names and `make new slide … base slide`. |
| **JXA shape `fills[0].color`** | Fails type conversion. | Don’t rely on it; use AS where possible or accept gap. |
| **Minimum table size** | Creating a true 1×1 table can error (`Invalid column count`). | Use ≥2 columns when creating tables. |
| **`osascript -e` size / escaping** | Large digests / payloads can break. | Scripts written to **temp files**. |
| **Automation / Hardened Runtime** | Without Apple Events entitlement + user consent, all scripting fails (“execution error”). | Entitlement `com.apple.security.automation.apple-events`; README permissions section. |
| **Slide insert position** | “After current” is less reliable than beginning/end across versions. | Prefer `end` / `beginning`. |

## What *is* scriptable (and used or available to KeynoteGPT)

- Documents: create/open/theme name, size  
- Slides: add/delete/duplicate, skip, presenter notes, default title/body text, transitions  
- Layouts: list names (via AS), assign `base slide` on create  
- Shapes / text items: create, position, size, opacity, rotation, `object text`, text font/size/color  
- Tables: create, cell `value`, `background color`, `text color` (good for colored grids — **not** a substitute when the user asked for shape boxes)  
- Images / movies / audio: file-based add (paths)  
- Export: PDF, slide images, PowerPoint, etc.  
- Slideshow play commands  

## KeynoteGPT action coverage vs gaps

| User intent | Action | Status |
|-------------|--------|--------|
| Title / bullets slide | `add_content_slide`, `set_title`, `set_body` | Supported |
| Real boxes (shapes) | `add_labeled_boxes`, `add_labeled_shape`, `add_shape` | Supported (fill color hard-gap) |
| Colored table grid | `add_color_table` | Supported (explicit table — not “boxes”) |
| Opacity / rotation | `set_opacity`, `set_rotation` | Supported |
| Font / text color | `set_text_style` | Supported |
| Move / resize | `move_element`, `resize_element` | Supported |
| Delete object | `delete_element` | Supported |
| Image | `add_image` | Supported |
| Transition | `set_transition` | Supported |
| Export | `export_presentation` | Supported |
| Shape fill RGB | — | **Hard gap** |
| Object builds | — | **Hard gap** |

## Permissions required

1. **Automation** — KeynoteGPT → Keynote (required for all scripting).  
2. **Accessibility** — optional; only for best-effort Shape Style UI clicks.  
3. **Gatekeeper** — Right-click → Open for ad-hoc release builds.

## References

- Keynote scripting dictionary: Script Editor → File → Open Dictionary → Keynote  
- [iWork Automation — Keynote shapes](https://iworkautomation.com/keynote/shape-line-shape.html) (fill type read-only)  
- Community consensus: shape fill cannot be set via AppleScript/JXA; UI scripting is the only partial workaround.
