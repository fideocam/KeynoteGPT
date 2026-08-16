# KeynoteGPT

macOS companion that adds local LLM support to Apple Keynote — the same digest → Ollama → allowlisted JSON actions pattern as BlenderGPT / ArchiGPT / Inkscape.

Keynote has no plugin SDK, so this app sits beside Keynote and drives it with JavaScript for Automation (JXA).

## Requirements

- macOS 14+
- [Keynote](https://apps.apple.com/app/keynote/id409183694)
- [Ollama](https://ollama.com) running locally (default `http://127.0.0.1:11434`)
- Xcode 15+ (to build)

## Build & run

```bash
cd ~/Projects/KeynoteGPT
open KeynoteGPT.xcodeproj
```

Or from the terminal:

```bash
xcodebuild -scheme KeynoteGPT -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/KeynoteGPT.app
```

On first Keynote control, macOS will ask for **Automation** permission (KeynoteGPT → Keynote). Allow it under **System Settings → Privacy & Security → Automation**.

## Usage

1. Start Ollama and pull a model (`ollama pull llama3.2` or similar).
2. Open a Keynote document.
3. Launch KeynoteGPT (window + menu bar extra).
4. Set the model under **Settings** if needed.
5. Ask for analysis (“summarize this deck”) or changes (“add a closing slide with three takeaways”).

**Digest** in the toolbar shows the presentation snapshot sent to the model.

## Architecture

| Piece | Role |
|-------|------|
| `OllamaClient` | Streaming `/api/chat` + `/api/tags` |
| `KeynoteBridge` | JXA via `osascript` — digest + apply actions |
| `ActionParser` | Extract `{"actions":[...]}` from model output |
| `AgentOrchestrator` | Digest → prompt → LLM → apply |
| `Prompts/` | Editable system rules + action schema |

Analysis replies stay as chat text. Change requests must return JSON actions from the allowlist in `Prompts/action_schema.txt`.

## Security tests

```bash
xcodebuild test -scheme KeynoteGPT -configuration Debug -derivedDataPath build
```

Coverage focuses on LLM/tool abuse surfaces:

- JXA string injection (`JSStringEscaperSecurityTests` — round-trips through real `osascript`)
- Action allowlisting / unknown ops (`ActionAllowlistSecurityTests`)
- Parser + sanitizer (`ActionParserSecurityTests`)
- Ollama URL SSRF/scheme restrictions (`OllamaEndpointValidatorSecurityTests`)

## Notes

- Operates on the **frontmost** Keynote document.
- Slide indexes are **0-based**; `-1` means last slide after earlier actions in the same batch.
- Some Keynote UI features (complex builds, every formatting knob) are outside the scripting dictionary — extend `KeynoteBridge` carefully, and avoid GUI scripting unless necessary.
