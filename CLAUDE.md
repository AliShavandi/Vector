# CLAUDE.md

This file gives Claude Code persistent context for the **Vector** project. Read it at the start of every session.

## Project Overview

**Vector** is a Mac-native, performance-focused code editor in the spirit of Zed, built solo with Claude Code using Swift/AppKit instead of a custom Rust GPU-rendering stack — trading a slightly lower theoretical performance ceiling for a dramatically shorter path to a genuinely good v1, since native AppKit/Core Text rendering is already fast and already built.

**Non-negotiable constraints:**
- No Electron, no webview-based rendering for the editor core. Native AppKit/Core Text only.
- Mac-only. Do not add cross-platform abstractions "just in case" — they cost engineering time for a market we've explicitly opted out of.
- Solo developer + Claude Code. Favor incremental, demoable milestones over big-bang architecture. Do not over-engineer for a team that doesn't exist.
- The account system (below) is for sign-up/sign-in and user counting only — not sync, not collaboration. Don't add server-side state beyond what's needed for that.

## Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | Swift | ARC, not GC — no stop-the-world pauses, but be deliberate about retain/release overhead on hot paths |
| UI chrome | SwiftUI | Sidebars, settings, command palette, chat panel, login screen — anything that isn't the text viewport |
| Text viewport | AppKit (`NSTextView`-based), possibly extending `CodeEditSourceEditor` | SwiftUI's diffing is not built for redrawing thousands of styled glyphs every frame; do not build the editor viewport in SwiftUI |
| Text buffer | Custom, value-type-based (`struct`, `ContiguousArray`/`UnsafeMutableBufferPointer`) | This is the hottest path in the app (mutated every keystroke). Avoid deeply reference-counted class graphs here — ARC overhead compounds on high-churn structures. Consider a rope or piece-table structure, not a flat string. |
| Syntax parsing | tree-sitter (C library, via Swift interop) | Incremental parsing — only reparse the changed region. Grammar per language. |
| LSP client | Custom async client (Swift concurrency: `async`/`await`, actors) | Generic client, per-language server configs are the only "extension" part. Never block the main thread on LSP responses. |
| Debugging | DAP (Debug Adapter Protocol), generic client + pluggable adapters | Same "generic protocol, pluggable backend" philosophy as LSP |
| Search | Shell out to `ripgrep` | Don't hand-roll project-wide search |
| Extension scripting | JavaScriptCore (built into macOS) | Extensions are for non-hot-path logic only: LSP server configs, statusline, fuzzy finder, UI niceties, AI feature orchestration |
| On-device ML | Core ML (embeddings, small classifiers) + MLX (local LLM inference, Apple Silicon-native) | No cloud calls, no per-token cost, demonstrates real on-device ML engineering |
| Claude integration | Claude Code CLI/Agent SDK as a subprocess, wrapped in a SwiftUI chat panel | User authenticates via their own Claude subscription (OAuth handled by the CLI itself) — this app never holds an API key or absorbs token cost |
| Local MCP server | Custom, inside the editor (mirrors VS Code's `ide` MCP server pattern) | Loopback `ws://`, random port, token handshake via lock file — lets Claude Code call back into the editor to open diffs, read selection/diagnostics |
| **Backend / Accounts** | **Supabase (Postgres + Auth)** | Managed account system — real sign-up/log-in and a dashboard showing signup counts, with no server to host or maintain yourself. Not used for sync or collaboration (out of scope for now). |
| 3D/graph visualization | SceneKit (2D force-directed graph as the practical daily-use mode; 3D as an explore/showcase toggle) | Built from tree-sitter hierarchy + LSP call graph + embedding-based semantic clustering |

## Architecture: Core vs. Extension

This is the most important architectural rule in the project — violating it is the most likely way to wreck performance.

**Must live in native core (compiled Swift, never scripted):**
- Text buffer / rope mutation
- Rendering and input handling (keystroke-to-pixel path)
- Tree-sitter incremental parsing
- LSP transport (JSON-RPC framing, async I/O, request/response correlation, cancellation)
- The local MCP server

**Belongs in extensions (JavaScriptCore, hot-reloadable):**
- Per-language LSP server configuration (which command to launch, which file types map to it — NOT the transport itself)
- Statusline, fuzzy finder UI logic, file tree, git gutter
- Keymaps, autocmds, user config
- AI feature orchestration (prompt templates, when to trigger completion, RAG formatting) — calling into native "AI services" APIs, not reimplementing inference in script

**Belongs in app shell (SwiftUI, independent of core/extension split):**
- Sign-up/log-in screen, account state, Supabase client calls
- Launch screen, onboarding flow, settings screen
- This work has no interaction with the buffer/rendering hot path and can be built in parallel with core editor phases, not strictly gated behind them

When in doubt: if it runs on every keystroke or every frame, it's core. If it's configuration or occasional-use orchestration, it's an extension. If it's account/onboarding/chrome, it's app shell.

## Directory Structure (proposed — adjust as the project grows, keep this section current)

```
/App                 — App entry point, window management, menu bar, launch screen
/Account             — Sign-up/log-in UI, Supabase client, account state (app shell, not core)
/Core
  /Buffer            — Text buffer / rope, value-type internals
  /Rendering         — NSTextView-based viewport, Core Text integration
  /Syntax            — tree-sitter bindings, grammar loading
  /LSP               — Generic async LSP client (transport only)
  /DAP               — Generic debug adapter client
  /MCP               — Local MCP server (loopback, diff callbacks, diagnostics passthrough)
  /AIServices        — Core ML / MLX inference services (embeddings, local LLM), exposed to extensions
/Extensions
  /JSRuntime         — JavaScriptCore embedding, extension API surface
  /BuiltIn           — Bundled extensions: LSP configs per language, statusline, fuzzy finder, git panel, AI orchestration
/UI                  — SwiftUI chrome: sidebars, command palette, settings, Claude chat panel
/Visualization       — SceneKit-based project graph (2D/3D)
/Tests
```

## Build & Test

_Fill in once the Xcode project / Swift package is scaffolded:_
- Build: `xcodebuild -scheme Vector build` or `swift build`
- Test: `xcodebuild test -scheme Vector -only-testing:VectorTests -destination 'platform=macOS'`
- Lint/format: (decide on `swift-format` or SwiftLint and record the command here)

## Coding Conventions

- Prefer `struct` over `class` for the buffer/rope internals; reserve `class`/ARC for UI-layer and non-hot-path state.
- All LSP and MCP I/O must be `async` and off the main actor; never block the render loop waiting on a language server or subprocess.
- New extension-surface APIs (functions exposed to JavaScriptCore) should be added deliberately, driven by what a real extension needs — do not pre-design a large API up front.
- Every new language support = one tree-sitter grammar + one LSP server config extension. Don't hardcode language-specific logic into core.
- The editor must be usable without signing in — account sign-up is additive (for the user-count dashboard), never a gate on core functionality.

## Roadmap Reference

See the project plan doc for the full phase breakdown, including Phase 2.5 (Backend & User Accounts). Current phase: **Phase 0 — Project Setup** (update this line as phases complete, so a fresh Claude Code session immediately knows where the project stands).

## Working With Claude Code On This Project

- Use **Plan mode** before any change that touches the core/extension boundary, the buffer's memory model, or the MCP protocol surface — these are expensive to redo.
- Keep unrelated phases in separate sessions (`/clear` between them) so context stays focused on the current subsystem.
- When adding a new LSP language extension or tree-sitter grammar, treat it as a repeatable workflow — worth turning into a project skill once you've done it twice.
- Run the build after every non-trivial change; don't let Swift compile errors stack up across multiple edits.
- The account/backend track (Supabase) is independent of the core editor track — it's fine to work on it in a separate session without having finished Phases 1–4 first.
