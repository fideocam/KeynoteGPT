# KeynoteGPT

macOS companion that adds local LLM support to Apple Keynote — the same digest → Ollama → allowlisted JSON actions pattern as BlenderGPT / ArchiGPT / Inkscape.

Keynote has no plugin SDK, so this app sits beside Keynote and drives it with JavaScript for Automation (JXA).

## Download a prebuilt app (no Xcode needed)

Grab the latest macOS build from **[Releases](https://github.com/fideocam/KeynoteGPT/releases)** ([v0.2](https://github.com/fideocam/KeynoteGPT/releases/tag/v0.2)):

1. Download **KeynoteGPT-0.2-macOS.zip** and unzip it.
2. Open `KeynoteGPT.app`. Because the build is ad-hoc signed (not notarized), macOS may block it the first time — use **Right-click the app → Open → Open**.
3. Start [Ollama](https://ollama.com) and pull a model if needed (`ollama pull llama3.2`).
4. Open a Keynote document, then use KeynoteGPT.

### Permissions you must accept

KeynoteGPT cannot edit slides until macOS allows it to control Keynote:

| Prompt / setting | What to do |
|------------------|------------|
| **Automation** (KeynoteGPT wants to control Keynote) | Click **OK** / allow when asked |
| Or manually: **System Settings → Privacy & Security → Automation** | Enable **Keynote** under **KeynoteGPT** |
| First launch Gatekeeper warning | **Right-click → Open** (ad-hoc signed build) |

Optional check: in KeynoteGPT **Settings**, press **Test Keynote digest**. It should report success when Keynote is open and Automation is granted.

Current prebuilt zip targets **Apple Silicon (arm64)**. Intel Mac users should build from source for now.

## Requirements

- macOS 14+
- [Keynote](https://apps.apple.com/app/keynote/id409183694)
- [Ollama](https://ollama.com) running locally (default `http://127.0.0.1:11434`)
- Xcode 15+ only if you build from source

## Build & run from source

```bash
cd ~/Projects/KeynoteGPT
open KeynoteGPT.xcodeproj
```

Or from the terminal:

```bash
xcodebuild -scheme KeynoteGPT -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/KeynoteGPT.app
```

## Usage

1. Start Ollama and pull a model (`ollama pull llama3.2` or similar).
2. Open a Keynote document.
3. Launch KeynoteGPT (window + menu bar extra).
4. Set the model under **Settings** if needed.
5. Ask for analysis (“summarize this deck”) or changes (“add a closing slide with three takeaways”, “a rounded box for each dwarf”).

**Digest** in the toolbar shows the presentation snapshot sent to the model.

## Architecture

| Piece | Role |
|-------|------|
| `OllamaClient` | Streaming `/api/chat` + `/api/tags` |
| `KeynoteBridge` | JXA / AppleScript — digest + apply actions |
| `ActionParser` | Extract `{"actions":[...]}` from model output |
| `AgentOrchestrator` | Digest → prompt → LLM → apply |
| `Prompts/` | Editable system rules + action schema |

Analysis replies stay as chat text. Change requests must return JSON actions from the allowlist in `Prompts/action_schema.txt`.

## Security tests

```bash
xcodebuild test -scheme KeynoteGPT -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64'
```

Coverage focuses on LLM/tool abuse surfaces:

- JXA string injection (`JSStringEscaperSecurityTests` — round-trips through real `osascript`)
- Action allowlisting / unknown ops (`ActionAllowlistSecurityTests`)
- Parser + sanitizer (`ActionParserSecurityTests`)
- Ollama URL SSRF/scheme restrictions (`OllamaEndpointValidatorSecurityTests`)

## Notes

- Operates on the **frontmost** Keynote document.
- Slide indexes are **0-based**; `-1` means last slide after earlier actions in the same batch.
- Some Keynote UI features (complex builds, every formatting knob) are outside the scripting dictionary — see [`docs/KEYNOTE_SCRIPTING_GAPS.md`](docs/KEYNOTE_SCRIPTING_GAPS.md).
- Shape **fill color** cannot be set via AppleScript (Apple limitation). Boxes are still real shape objects; fills may need Format → Style / Accessibility best-effort.

## Related projects

Closest GitHub neighbors (mostly **MCP servers** for Claude/Cursor, not standalone Ollama companions):

| Project | Notes |
|---------|--------|
| [easychen/keynote-mcp](https://github.com/easychen/keynote-mcp) | Popular Keynote MCP via AppleScript |
| [ByAxe/keynote-mcp](https://github.com/ByAxe/keynote-mcp) | Fork / continuation of keynote-mcp |
| [superdwayne/keynoteMP](https://github.com/superdwayne/keynoteMP) | Broader Keynote MCP + design engine |
| [reichenbach/iwork_mcp](https://github.com/reichenbach/iwork_mcp) | Numbers + Pages + Keynote MCP |
| [PsychQuant/che-keynote-mcp](https://github.com/PsychQuant/che-keynote-mcp) | Swift-native Keynote MCP |
| [sandeeffendi/keynote-companion-macos](https://github.com/sandeeffendi/keynote-companion-macos) | macOS Keynote companion (different stack) |

KeynoteGPT is intentionally a **native SwiftUI + Ollama** companion (BlenderGPT-style), not an MCP server.
