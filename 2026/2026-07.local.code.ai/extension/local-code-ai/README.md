# Local Code AI

Chat with a **local Ollama model** about the project you have open, and refactor/format
**Go, PowerShell, Rust and JavaScript** using local tools only. Each file gets a
deterministic formatter pass (gofumpt/gofmt, PSScriptAnalyzer's Invoke-Formatter,
rustfmt, prettier), then an LLM pass for conservative refactoring and comment
cleanup, then the formatter once more to normalize the result.

Edits are **auto-applied and saved**. Nothing is ever committed to git.

## Chat

Ctrl/Cmd+Shift+P → **Local Code AI: Open Chat** opens the chat as a normal
**editor tab**, so you can move it between groups, split it, or drag it wherever
you like. The **Local Code AI** icon in the activity bar is a launcher for the
same tab: clicking it opens the editor-tab chat and closes the side bar, so the
chat never squats where the Explorer lives. A chat docked in the side bar is
still available on request — run **Open Chat in Side Bar**, or set
`localCodeAI.chatOpenIn` to `sidebar` to make every surface (icon included)
prefer the side bar. The two surfaces keep separate conversations — moving
between them does not carry the transcript over.

Type a prompt and press **Enter** (Shift+Enter for a new line). Replies stream
from the local model. While the model works — before the first token and between
tool calls — the transcript shows a pulsing status line that cycles through the
words in `cli/progress.txt` (*Thinking*, *Pondering*, *Reasoning*, ...), growing
a dot per second (up to 6) before moving to the next word, so long waits (e.g.
CPU-only inference) are visibly alive. When the reply finishes, the chat signs
off with the next line from `cli/done.txt` (*Done! Ready for more.*, ...),
round-robin, so the end of a long answer is unmistakable. Edit either file (one
entry per line, in the `cli` folder next to `extension.js`) to change the lines.

### It knows about your project

With **Project context** ticked (the default) every message carries a *live*
snapshot of the workspace: the folders you have open, the file list, the open
editors, the active file and cursor/selection, and the current error/warning
counts. On top of that the model can call read-only tools to inspect the code
itself, so "fix the typos in this project" works without pasting anything:

| Tool | What the model can do |
|---|---|
| `list_files` | List workspace files, optionally by glob |
| `read_file` | Read a file (unsaved editor changes included) |
| `search_text` | Search the workspace by string or regex |
| `get_diagnostics` | Read current problems from the language servers |
| `get_active_editor` | See the file, selection and text you are looking at |

Each tool call appears in the transcript (🔍 `read src/main.go`) so you can see
what was consulted. Tools are **read-only** and confined to the open workspace
folders — paths outside them are refused, and the chat never writes files. To
have the model actually change code, use the refactor commands below.

Tool use needs a tool-capable model (`qwen3-coder`, `qwen3`, ...). If the
model rejects tools the chat says so once and carries on with the workspace
summary alone. Small models often *accept* tools but then write the call as a
JSON snippet in the reply instead of invoking it; the chat recognizes those
(fenced, `<tool_call>`-tagged, or bare JSON naming a real tool), runs the tool,
and keeps the conversation going instead of showing you raw JSON. Set
`localCodeAI.chatTools` to `false` to turn tools off.

### Toolbar

- **Project context** — workspace snapshot + tools (above).
- **Active file** / **Selection** — paste the active editor's full text or just
  the selection into the message.
- **Attach...** — pick specific files to send with the next message.
- **New chat** — clears the conversation history.
- **Send** turns into **Stop** while a reply is streaming.

The chat uses the `localCodeAI.endpoint`, `localCodeAI.model`,
`localCodeAI.temperature` and `localCodeAI.chatSystemPrompt` settings.

## Commands (Ctrl/Cmd+Shift+P)

- **Local Code AI: Open Chat** - opens the chat where `localCodeAI.chatOpenIn` says
  (default: an editor tab).
- **Local Code AI: Open Chat in Editor Tab** / **Open Chat in Side Bar** - pick a
  surface explicitly.
- **Local Code AI: Refactor & Format Current File** - processes the active editor,
  applies the result as a normal edit (undo works), then saves.
- **Local Code AI: Refactor & Format Workspace** - processes every supported file in
  the open workspace, writing changes to disk. Shows a confirmation dialog first when
  more than `localCodeAI.maxFilesBeforeWarning` files (default **50**) would be touched.
  The run is cancellable; a summary appears when it finishes.
- **Local Code AI: Check Setup (Ollama + tools)** - verifies the Ollama endpoint, that
  the model exists **and actually loads**, which models are in memory, and each
  formatter; prints a report (with fix instructions on failure) to the *Local Code AI*
  output channel.
- **Local Code AI: Start Model** - starts the Ollama server if it is down (as a
  detached external process) and loads the model into memory, so the first prompt
  answers immediately.
- **Local Code AI: Stop Model** - asks how far to go: *unload the model* (frees
  GPU/RAM, server keeps running) or *stop the Ollama server* (frees everything,
  affects every window using it).

## Model lifecycle

The Ollama server is an **external process**, not part of the extension: one
instance at `localCodeAI.endpoint` serves every VS Code window (and your
terminal), and it keeps running when VS Code closes. The extension checks at
startup that the server is up and the model exists, and shows an actionable
error if not (with a **Start Model** button). Ollama evicts an idle model from
memory after ~5 minutes by default, so memory is not held forever even without
intervention; **Stop Model** frees it immediately, and **Start Model** brings
everything back (auto-detects the `ollama` binary; override with
`localCodeAI.ollamaPath`). Both commands manage the server **on this machine**:
with a remote `localCodeAI.endpoint` they refuse and tell you to act on that
host instead.

Both refactor commands show a progress notification that cycles through the words
in `cli/progress.txt` with a growing trail of dots while the model works.

## Key settings

| Setting | Default | Meaning |
|---|---|---|
| `localCodeAI.endpoint` | `http://127.0.0.1:11434` | Ollama server |
| `localCodeAI.model` | `localcoder` | Model or alias used for chat and refactoring |
| `localCodeAI.ollamaPath` | (auto-detect) | `ollama` executable used by **Start Model** |
| `localCodeAI.chatSystemPrompt` | (project-aware local assistant) | System prompt; the workspace snapshot is appended to it |
| `localCodeAI.chatOpenIn` | `editor` | Where **Open Chat** opens: `editor` tab or `sidebar` |
| `localCodeAI.chatTools` | `true` | Let the chat read/search the workspace via tools |
| `localCodeAI.chatMaxToolRounds` | `8` | Tool rounds allowed before the model must answer |
| `localCodeAI.chatContextFileLimit` | `400` | Paths listed in the workspace snapshot |
| `localCodeAI.chatMaxReadKB` | `64` | Cap on any single file the chat reads/attaches |
| `localCodeAI.maxFilesBeforeWarning` | `50` | Warn before touching more files than this in one run |
| `localCodeAI.llmPass` | `true` | Set `false` for formatter-only runs |
| `localCodeAI.timeoutSeconds` | `300` | Per-file timeout for the LLM request (raise on slow CPU-only machines) |
| `localCodeAI.maxFileKB` | `128` | Bigger files get formatter-only treatment |
| `localCodeAI.excludeGlobs` | node_modules, .git, vendor, target, ... | Skipped in workspace runs |

## Troubleshooting

- **"Ollama not reachable"** - run **Local Code AI: Start Model** (also offered as a
  button on the error), start it yourself (`ollama serve`), or re-run the setup
  script (`local.code.ai.ps1`).
- **"Model not found"** - the store at the endpoint has no `localCodeAI.model`;
  re-run the setup script to (re)create the alias, or point the setting at an
  existing model. **Check Setup** lists what is available.
- **A formatter shows MISSING in Check Setup** - re-run the setup script (it re-fetches
  missing tools), or install the tool yourself; PATH is used as a fallback. Tool
  locations are read from `<root>/tools/paths.json`, where root is the
  `localCodeAI.toolsRoot` setting, else the `LOCALCODEAI_HOME` environment variable,
  else `C:\LocalCodeAI` / `~/LocalCodeAI`.
- The LLM pass refuses suspicious outputs (empty or drastically shortened files) and
  keeps the original in that case.
- **The chat says it cannot see your code** - check that a folder is actually open
  (not a single loose file), that **Project context** is ticked, and that the model
  supports tools; `localCodeAI.chatMaxToolRounds` may also be too low for a big ask.
- **The chat cannot find a file it should see** - the file list hit
  `localCodeAI.chatContextFileLimit` (the model can still reach the file with
  `list_files`/`search_text`), or the file matches `localCodeAI.excludeGlobs` —
  excluded files are hidden from `list_files` and `search_text` too, though
  `read_file` with the exact path still works.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](https://yuruna.com)
