# Local Code AI — shared server + Continue client

Two PowerShell 7 scripts that turn the design in
[docs/ryzen-ai-halo-review-server.md](docs/ryzen-ai-halo-review-server.md) into
something you can run:

| Script | Runs on | What it does |
|---|---|---|
| `local.code.server.ps1` | the Halo box (Linux x64) | downloads the five models into `.\models`, serves them over an OpenAI-compatible API, prints the URL |
| `local.code.client.ps1` | any workstation (Windows, macOS, Linux) | installs/updates the **Continue.continue** VS Code extension and points it at that URL |

Everything the server needs lives **inside the current folder**. No sudo, no
system service, no nginx, nothing installed system-wide.

## Quick start

On the server (an AMD Ryzen AI Max+ "Strix Halo" running Debian 13):

```powershell
cd ~/localcode          # any folder you like; models/ bin/ run/ are created here
pwsh ./local.code.server.ps1
```

The first run downloads about **145 GiB** of weights, so give it time and disk.
When it finishes it prints something like:

```
    OpenAI base URL : http://192.168.1.50:8888/v1
    llama-swap UI   : http://192.168.1.50:8888/
    models          : interactive, deep-reviewer, second-opinion, code-embed, code-fim
```

On each workstation:

```powershell
pwsh ./local.code.client.ps1 -ServerUrl http://192.168.1.50:8888
```

Then reload the VS Code window, open the Continue side bar, and pick the
**local-code-ai** assistant.

## The models

Roles are chosen so the three chat models cover different failure modes — one
fast, one deep, one from a different training lineage for cross-checking
(Section 5 of the design document).

| llama-swap id | Model | Size | Continue role |
|---|---|---|---|
| `interactive` | Qwen3-Coder-30B-A3B-Instruct UD-Q5_K_XL | 20 GiB | chat, edit, apply |
| `deep-reviewer` | gpt-oss-120b MXFP4 (reasoning effort `high`) | 59 GiB | chat, edit |
| `second-opinion` | GLM-4.5-Air UD-Q4_K_XL | 63 GiB | chat |
| `code-embed` | Qwen3-Embedding-0.6B Q8_0 | 0.6 GiB | embed (`@codebase`) |
| `code-fim` | Qwen2.5-Coder-3B **base** Q6_K | 2.4 GiB | autocomplete |

`interactive`, `code-embed` and `code-fim` stay resident (~32 GB); the two
heavyweights take turns, so peak memory stays near 102 GB inside the ~112 GiB the
GPU can address. Switching between the heavyweights costs a 60–90 s reload — that
is the price of running two 100B-class models on one box.

Both scripts pin these specific checkpoints. The *tiering logic* outlives any
particular one: swap the names in `$script:Catalog` (server) and
`$script:ModelSpec` (client), keep the shape.

## What each script does

### local.code.server.ps1

1. **Platform gate** — Linux x64 only; anywhere else it explains and exits. Then
   advisory checks: memory, `/dev/dri/renderD*`, `render`/`video` group
   membership, a Vulkan loader, free disk.
2. **Engine** — downloads the prebuilt llama.cpp **Vulkan** build and the
   llama-swap release binary into `.\bin`. Re-runs upgrade them when a newer
   release exists.
3. **Models** — downloads into `.\models`. Sizes and content hashes come from a
   HEAD against Hugging Face, so a file is re-fetched only when it actually
   changed upstream, and interrupted downloads resume.
4. **Configuration** — generates `.\run\llama-swap.yaml` (model commands,
   contexts, TTLs, memory groups).
5. **Serving** — starts llama-swap detached, waits for `/v1/models` to answer,
   prints the URL.

Idempotent: re-running updates the engine and any changed weights, leaves a
healthy server running, and restarts it only when the configuration changed.
**Offline it keeps working** — when Hugging Face or GitHub cannot be reached it
logs why and serves whatever is already on disk.

Lifecycle: `-Status`, `-Stop`, `-Restart`.
Other switches: `-Port`, `-BindAddress`, `-ModelsPath`, `-NoDownload`, `-Yes`, `-Force`.

### local.code.client.ps1

1. **VS Code** — finds the `code` CLI on PATH, in the usual install locations, or
   via Flatpak. If VS Code is missing it prints platform-specific install
   instructions and exits.
2. **Extension** — installs `Continue.continue`, or updates it, and reports the
   version change.
3. **Server URL** — takes `-ServerUrl` or asks for it (a trailing `/v1` is
   accepted), then probes `/v1/models` to confirm the server answers and to learn
   which models it actually serves — entries for models the server does not offer
   are left out.
4. **Configuration** — writes `~/.continue/assistants/local-code-ai.yaml`.

Continue loads that file **alongside** any existing `config.yaml`, so your own
configuration is never touched. Re-runs rewrite it and keep a timestamped backup
whenever the previous content differed. Use `-Scope workspace` to write
`.continue/assistants/` in the current folder instead, so the setting travels with
the repository.

Other switches: `-ApiKey`, `-AssistantName`, `-SkipExtension`, `-Yes`, `-Force`.

## Layout

```
2026-08.local.code.ai\
├── local.code.server.ps1     server: weights + llama-swap
├── local.code.client.ps1     client: VS Code + Continue
└── docs\
    └── ryzen-ai-halo-review-server.md   the full design (OS, GPU, nginx, TLS, ops)
```

Created by the server in the folder it runs from (all git-ignored):

```
models\      the five GGUF models, one folder each
bin\         llama.cpp\ (llama-server + libs) and llama-swap
run\         llama-swap.yaml, llama-swap.log, llama-swap.pid, models.json, tools.json
```

## Notes & caveats

- **No authentication.** The server binds `0.0.0.0` and anyone on the LAN can use
  it. That matches Section 14 of the design document — on an untrusted network put
  it behind the nginx + token + TLS front door described there. Continue still
  needs the `apiKey` field, so a placeholder is written.
- The design document also covers a second engine (Ollama) for this repo's own
  extension. These scripts serve **only** the OpenAI-compatible API, which is all
  Continue speaks.
- `-c` is the *total* KV cache, split across `--parallel` slots: `-c 262144
  --parallel 4` gives four concurrent users 64K each, not four users with 256K.
  The client writes a matching `contextLength: 65536`.
- Requests beyond `--parallel` queue inside `llama-server` — they wait, they do
  not fail.
- The first request after an idle period can be slow: the model was evicted. Raise
  `ttl` in `run/llama-swap.yaml` if that annoys you.
- The server survives logout (it is started with `nohup`) but **not a reboot** —
  re-run the script, or wrap it in a systemd unit as shown in Section 9 of the
  design document.
- Autocomplete uses the raw completions endpoint (`useLegacyCompletionsEndpoint:
  true`); an instruct-tuned model would be wrong for fill-in-the-middle.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol.

Last review: 2026.08.04

Back to [Yuruna](https://yuruna.com)
