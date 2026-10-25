# Vector

A Mac-native, performance-focused code editor in the spirit of [Zed](https://zed.dev), built with Swift and AppKit.

Rather than a custom GPU-rendering stack, Vector leans on native AppKit and Core Text rendering, which is already fast and already built. That trades a slightly lower theoretical performance ceiling for a much shorter path to a genuinely good v1.

> **Status:** Phase 0, project setup. The directory skeleton is in place; there's no working editor yet.

## Principles

- **Native only.** No Electron, no webview rendering in the editor core.
- **Mac only.** No cross-platform abstractions.
- **Fast core, scriptable edges.** Anything on the keystroke-to-pixel path (text buffer, rendering, tree-sitter parsing, LSP transport) is compiled Swift. Configuration and occasional-use features (language server configs, statusline, fuzzy finder, keymaps) are JavaScriptCore extensions.

## Planned stack

| Area | Technology |
|---|---|
| Text viewport | AppKit (`NSTextView`) + Core Text |
| UI chrome | SwiftUI |
| Text buffer | Custom value-type rope / piece table |
| Syntax | tree-sitter (incremental parsing) |
| Language intelligence | Generic async LSP client |
| Debugging | Generic DAP client with pluggable adapters |
| Search | ripgrep |
| Extensions | JavaScriptCore |
| On-device ML | Core ML + MLX |
| AI assistant | Claude Code CLI as a subprocess, plus a local MCP server so it can call back into the editor |
| Project graph | SceneKit (2D force-directed, optional 3D) |

## Layout

```
Vector/
  App/            App entry point, window management
  Core/           Buffer, Rendering, Syntax, LSP, DAP, MCP, AIServices
  Extensions/     JavaScriptCore runtime and bundled extensions
  UI/             SwiftUI chrome
  Visualization/  SceneKit project graph
VectorTests/      Unit tests
VectorUITests/    UI tests
```

## Building

Requires Xcode on macOS 27 or later.

```sh
xcodebuild -scheme Vector -destination 'platform=macOS' build
xcodebuild -scheme Vector -destination 'platform=macOS' test
```

Or open `Vector.xcodeproj` in Xcode and run the `Vector` scheme.
