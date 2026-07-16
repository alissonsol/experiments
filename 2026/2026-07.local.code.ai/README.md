# Local Code AI — setup

One script, `local.code.ai.ps1`, that turns a machine into a local code-assistant
station: a **chat** in VS Code (editor tab or side bar) backed by a local model,
plus refactor/format commands for **Go, PowerShell, Rust and JavaScript**.
Everything runs locally; nothing leaves the machine.

Works on **Windows, macOS and Ubuntu**. A GPU is optional: with a capable NVIDIA
card (or ample Apple unified memory) you get a larger model and fast replies;
without one the script picks a small model and runs it on CPU — fully functional,
just slow.

## Quick start

Prerequisites: [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
and VS Code. Everything else is downloaded by the script.

```powershell
# Windows
pwsh -ExecutionPolicy Bypass -File .\local.code.ai.ps1

# macOS / Ubuntu
pwsh ./local.code.ai.ps1

# Non-interactive (auto-accepts prompts, e.g. the CPU-only confirmation)
pwsh ./local.code.ai.ps1 -Yes
```

Then reload VS Code and run **Ctrl/Cmd+Shift+P → "Local Code AI: Check Setup (Ollama + tools)"**.

## What the script does

1. **Checks prerequisites** — total RAM (warns under 32 GB), GPU (NVIDIA VRAM via
   `nvidia-smi` on Windows/Linux; unified memory on macOS), and free disk space on
   the target drive (hard stop if short, override with `-Force`). **A missing GPU
   does not stop the run** — the script asks to confirm CPU-only inference
   (auto-accepted with `-Yes`).
2. **Installs Ollama** if missing (per-platform methods: see *Platform notes*
   below) and points `OLLAMA_MODELS` at `<Root>/models` so the weights live
   inside one folder. On Ubuntu, a packaged `ollama.service` (whose service user
   cannot read your home folder) is disabled — this needs sudo — in favor of a
   per-user server; restore it any time with `sudo systemctl enable --now ollama`.
   Without sudo, the system service and its default model store are kept.
3. **Downloads a coder model sized to your hardware** — ≥ 20 GB VRAM or ≥ 32 GB
   unified memory → `qwen3-coder:30b` (~19 GB download); ≥ 11 GB VRAM or ≥ 18 GB
   unified memory → `qwen2.5-coder:14b`; ≥ 7 GB VRAM → `qwen3:8b` (the 7B coder
   fumbles native tool calls, so this tier trades a little coding depth for a
   chat that can actually read the project); below
   that → `qwen2.5-coder:7b` with an 8k context — and creates the Ollama alias
   **`localcoder`** with an enlarged context window (override with `-ModelTag` /
   `-ContextTokens`).
4. **Assembles the formatter toolchain** ("use installed, fetch missing"):
   gofumpt (with gofmt fallback), rustfmt, portable Node.js + prettier, and
   PSScriptAnalyzer. Locations are recorded in `tools\paths.json`.
5. **Packages and installs the VS Code extension.** The extension source lives in
   [`extension/local-code-ai/`](extension/local-code-ai/) next to the script (edit
   it there); the script copies it to `<Root>\extension\local-code-ai`, packages it
   with vsce and installs the `.vsix`.

## Using it in VS Code

**Chat:** Ctrl/Cmd+Shift+P → "Local Code AI: Open Chat" (an editor tab by default);
the **Local Code AI** icon in the activity bar opens the same tab. (A side-bar
chat is still there on request: "Open Chat in Side Bar", or set
`localCodeAI.chatOpenIn` to `sidebar`.)
Enter sends, Shift+Enter adds a newline, replies stream from the local model, and
**Send** turns into **Stop** mid-reply. While the model works, a pulsing
*Thinking...* line grows a dot per second so long waits stay visibly alive,
and each finished reply signs off with a rotating *Done! Ready for more.* line.
With **Project context** on (the default) each message carries a live workspace
snapshot and the model can read project files through read-only tools;
**Active file**, **Selection** and **Attach...** add specific content, and
**New chat** clears the conversation. The tool list and all settings are in the
[extension README](extension/local-code-ai/README.md); sample prompts in
[prompts.txt](prompts.txt).

| Command | What it does |
|---|---|
| **Open Chat** | opens the chat (editor tab by default; `localCodeAI.chatOpenIn`) — the activity-bar icon opens the same tab |
| **Open Chat in Editor Tab** / **in Side Bar** | pick a chat surface explicitly |
| **Refactor & Format Current File** | formatter → LLM refactor + comment cleanup → formatter; applied as an editor edit (undo works) and saved |
| **Refactor & Format Workspace** | same pipeline over every supported file in the open project; cancellable, with a summary at the end |
| **Check Setup (Ollama + tools)** | verifies Ollama, that the model exists and loads, and every formatter — failures come with fix instructions |
| **Start Model** | starts the Ollama server if down (detached external process, shared by all windows) and loads the model |
| **Stop Model** | unload the model (free GPU/RAM) or stop the Ollama server entirely |

The Ollama server runs as an **external process**: one instance serves every
VS Code window and survives closing them; the extension checks it at startup
and complains (with a Start Model button) when it is missing. Idle models are
evicted from memory after ~5 minutes by default — Stop Model frees them
immediately, Start Model warms them back up.

Edits are **auto-applied and saved — never committed**. Review with your normal
`git diff` and commit when happy.

A confirmation dialog appears when a workspace run would touch **more than 50
files**. Change the threshold in Settings → `localCodeAI.maxFilesBeforeWarning`
(or set `localCodeAI.llmPass: false` for fast formatter-only sweeps).

## Repo layout

```
2026-07.local.code.ai\
├── local.code.ai.ps1              setup script (prereqs, Ollama, model, tools, install)
├── prompts.txt                    sample prompts for the chat
└── extension\local-code-ai\       VS Code extension source
    ├── package.json               manifest (commands, chat view, settings)
    ├── extension.js               refactor/format pipeline + activation
    ├── chat.js                    chat: side-bar view + editor tab (webview ↔ Ollama /api/chat)
    ├── workspace.js               workspace snapshot + read-only chat tools (list/read/search, diagnostics)
    ├── model.js                   Ollama server/model lifecycle (probe, start detached, unload, stop)
    ├── cli\                       status lines: progress.txt (thinking words), done.txt (sign-offs)
    ├── media\local-code.svg       activity bar icon (talk bubble from a house)
    ├── README.md                  extension README (shipped in the .vsix)
    └── LICENSE                    MIT
```

## Install-target layout

Default root: `C:\LocalCodeAI` on Windows, `~/LocalCodeAI` on macOS/Linux
(change with `-Root`).

```
C:\LocalCodeAI\
├── models\        Ollama model store (OLLAMA_MODELS points here)
├── tools\         bin\gofumpt.exe, bin\rustfmt.exe, node\, prettier\, ps-modules\, paths.json
├── extension\     local-code-ai\ (copied source) + local-code-ai.vsix
└── downloads\     installers and archives
```

## Re-running / flags

The script is idempotent — re-run it any time. Useful switches:
`-SkipModel`, `-SkipTools`, `-SkipExtension`, `-ModelTag qwen2.5-coder:14b`,
`-ContextTokens 16384`, `-Root D:\LocalCodeAI`, `-KeepExistingOllamaModelPath`,
`-Yes` (non-interactive), `-Force`.

To rebuild just the extension after editing its source:
`pwsh -File .\local.code.ai.ps1 -SkipModel -SkipTools -Yes`

## Platform notes

- **Windows** — the most exercised path (winget with installer fallback).
- **macOS** (including UTM VMs) — Ollama via Homebrew when present, otherwise a
  portable GitHub build under `~/LocalCodeAI/tools/ollama`. Model sizing uses
  unified memory. Inside a VM there is no GPU acceleration — expect CPU speeds.
- **Ubuntu** (including arm64) — the official install script when `curl` is
  present, otherwise a portable GitHub build (no sudo needed). Formatters are
  fetched per-architecture; if none exists for your platform (e.g. rustfmt on
  some arm64 setups) that language is skipped and everything else keeps working.
- `ollama serve` is started in the background for the session; after a reboot,
  bring it back with the **Local Code AI: Start Model** command in VS Code,
  `ollama serve` in a terminal, or by re-running the script.

## Notes & caveats

- First run downloads the model weights (~5–19 GB depending on the tier) — that
  step dominates.
- CPU-only inference is slow. Chat is usable; for workspace-wide runs consider
  `localCodeAI.llmPass: false` (fast formatter-only sweeps).
- Reload VS Code after install so the extension activates.
- Chat behavior is controlled by `localCodeAI.endpoint` / `model` / `temperature` /
  `chatSystemPrompt` / `chatOpenIn` / `chatTools` / `chatMaxToolRounds` /
  `chatContextFileLimit` / `chatMaxReadKB`. The side-bar chat and an editor-tab
  chat keep separate histories, cleared by **New chat** (or by closing the tab).
- Files larger than `localCodeAI.maxFileKB` (default 128 KB) get the formatter pass
  only; the LLM pass also rejects suspicious outputs (empty/truncated) and keeps the
  original, logging the reason to the *Local Code AI* output channel.
- Work on a branch or with a clean tree — since edits auto-save, `git diff` is your
  review surface.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](https://yuruna.com)
