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

Then reload the VS Code window and open the Continue side bar. In the **top right**,
in the list of configurations, select **`local-code-ai.yaml`** instead of
**Main Config**, then choose a model.

## The models

Roles are chosen so the three chat models cover different failure modes — one
fast, one deep, one from a different training lineage for cross-checking
(Section 5 of the design document).

| llama-swap id | Model | Size | Continue role |
|---|---|---|---|
| `interactive` | Qwen3-Coder-30B-A3B-Instruct UD-Q5_K_XL | 20 GiB | chat, edit, apply |
| `deep-reviewer` | gpt-oss-120b MXFP4 (reasoning effort `medium`) | 59 GiB | chat, edit, apply |
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
   advisory checks: memory, whether this user can actually *open*
   `/dev/dri/renderD*`, a Vulkan loader, free disk.
2. **Engine** — downloads the prebuilt llama.cpp **Vulkan** build and the
   llama-swap release binary into `.\bin`, **once**. Re-runs keep the engine that
   works; pass `-UpdateEngine` to upgrade it deliberately. It then asks llama.cpp
   itself which GPUs it can see (`llama-server --list-devices`) and **stops if the
   answer is none** — see [No GPU?](#no-gpu) below.

   llama.cpp publishes a build roughly every 45 minutes, and GitHub creates the
   release record before the build matrix finishes uploading — so the newest tag
   regularly has no binaries attached yet. The script walks back through recent
   releases to the newest one that actually carries a Linux Vulkan asset, and if it
   cannot reach any, it keeps the engine already installed rather than failing.
   This also matches the design document's advice to treat engine upgrades as a
   deliberate, benchmarked step rather than something that happens on every run.
3. **Models** — downloads into `.\models`. Sizes and content hashes come from a
   HEAD against Hugging Face, so a file is re-fetched only when it actually
   changed upstream, and interrupted downloads resume.
4. **Configuration** — generates `.\run\llama-swap.yaml` (model commands,
   contexts, TTLs, memory groups).
5. **Serving** — starts llama-swap detached, waits for `/v1/models` to answer,
   **opens the port to the local subnet**, prints the URL, and then **follows the
   log** so you can watch activity. Ctrl+C stops watching; the server keeps
   running. `-NoFollow` skips the tail (use it for unattended runs).

   The firewall rule is scoped to the subnet of your real LAN interface — Docker
   and libvirt bridges are deliberately ignored, since opening the port to
   `172.17.0.0/16` would help nobody. It runs, via sudo and after printing the
   exact command:

   ```bash
   ufw allow from 192.168.7.0/24 to any port 8888 proto tcp
   ```

   firewalld is handled with an equivalent rich rule; if neither is installed, or
   the firewall is inactive, it says so and changes nothing. `-NoFirewall` opts out
   entirely.

Idempotent: re-running updates the engine and any changed weights, leaves a
healthy server running, and restarts it only when the configuration changed.
**Offline it keeps working** — when Hugging Face or GitHub cannot be reached it
logs why and serves whatever is already on disk.

Lifecycle: `-Status`, `-Stop`, `-Restart`.
Other switches: `-Port`, `-BindAddress`, `-ModelsPath`, `-NoDownload`, `-FixGroups`,
`-UpdateEngine`, `-NoFirewall`, `-NoFollow`, `-Yes`, `-Force`.

#### No GPU?

The render node `/dev/dri/renderD128` is normally owned by the `render` group. A
user outside that group cannot open it, so the Vulkan backend enumerates nothing
and llama.cpp **silently falls back to the CPU** — roughly 2 tokens/s instead of
40–55, which makes the 120B model unusable. That silence is the danger: the server
starts, answers, and is simply useless.

So the script asks llama.cpp directly and refuses to download 145 GiB for a CPU.
To fix the usual cause:

```powershell
pwsh ./local.code.server.ps1 -FixGroups     # runs: sudo usermod -aG render,video <user>
```

Then **log out and back in** and re-run normally. The re-login is not optional:
Linux reads a process's supplementary groups at login, so neither the script nor
any child of the current shell can pick up the new group. (`sg render -c '...'`
runs a single command with the new group if you cannot log out.) Override the stop
with `-Force` if you really do want CPU-only inference.

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
  not fail. That guarantee stops at the process boundary: see the next bullet.
- **A request that arrives while its model is not up gets a `502`, not a wait.**
  llama-swap only queues behind a *running* upstream. If the model was evicted by
  `ttl`, is mid-swap, or its `llama-server` died, the proxy answers `502 Bad
  Gateway` — sometimes after tens of seconds, sometimes in under 2 ms — and
  Continue surfaces that as a failed request rather than "loading". `ttl: 1800` on
  the two heavyweights means half an hour of quiet is enough to arm this. Raise
  `ttl` in `run/llama-swap.yaml` to widen the window; the retry always succeeds
  once the model is back.
- **`llama-server` upstreams do exit unexpectedly here.** A session driven hard
  enough to force repeated heavy-group swaps logged 21 `upstream process exited
  unexpectedly` events across `interactive` and `deep-reviewer`, plus one `group:
  starting deep-reviewer failed: upstream command exited prematurely`. llama-swap
  restarts the model on the next request, so the failure is self-healing and easy
  to miss — the visible symptom is an occasional `502`. The likely cause is the
  memory ceiling this configuration deliberately runs close to (~102 GB used of
  the ~112 GiB the GPU can address, before KV growth on four 64K slots), so
  overlapping loads have little room. Not reproduced under ordinary single-user
  editing. `curl http://<server>:8888/logs` is the place to check — grep for
  `exited unexpectedly`. If it shows up in normal use, lower `-c` or `--parallel`
  on the heavyweights before suspecting anything else.
- The server survives logout (it is started with `nohup`) but **not a reboot** —
  re-run the script, or wrap it in a systemd unit as shown in Section 9 of the
  design document.
- Autocomplete uses the raw completions endpoint (`useLegacyCompletionsEndpoint:
  true`); an instruct-tuned model would be wrong for fill-in-the-middle.

## Three things about Continue that cost an afternoon

These are properties of the extension, not of this server. All three were verified
against Continue **v2.0.0**; check them again before blaming the models.

**`capabilities: [tool_use]` is mandatory, and its absence fails silently.**
Continue decides whether a model can call tools by *string-matching the model id*.
For `provider: openai` it accepts `/^gpt-[4-9]/`, `/^o[1-9]/`, `codex`, and the
substrings `gpt-oss`, `exaone`, `gemma` — everything else returns false. Our ids
are llama-swap aliases (`interactive`, `deep-reviewer`), so all of them failed the
check no matter how capable the model behind them was. Continue does not warn. It
stops sending a `tools` array and quietly downgrades Agent mode to a text
imitation of tool calling, asking the model to type a `TOOL_NAME:` / `BEGIN_ARG`
fence as prose. Local models reproduce that fence unreliably, so the model
*describes* the edit and no file is ever written — Agent mode appears to work and
silently does nothing. Declaring `capabilities` short-circuits the name check.
The client script now writes it for every chat model.

**The model that writes the file is not always the one you picked.** Continue
resolves the writer as `selectedModelByRole.apply ?? selectedModelByRole.chat`. A
model with no `apply` role anywhere performs its own merges — which meant picking
the 120B reviewer made *it* do the mechanical diff, the slowest and least suitable
model for the job. Every chat model here now carries `apply`.

**Continue's lazy-apply prompt is Sonnet-only.** `lazyApplyPromptForModel` returns
a real prompt when the model name contains `sonnet` and `undefined` otherwise, so
every local model runs the apply path without the prompt written for it. Native
tool calls avoid most of this, but a merge that corrupts a file — duplicated
trailing lines, a lost final newline — is this, not the server. It is not
reachable from configuration.

## Measured on this box

Numbers from the Strix Halo server over the LAN, for calibration. Throughput is
what it is; the *effort* row is the one worth acting on.

| | `interactive` (30B) | `deep-reviewer` (120B) |
|---|---|---|
| Warm round trip, trivial request | 0.06 s | — |
| Prefill | 641 tok/s | 547 tok/s |
| Decode | ~50 tok/s | ~47 tok/s |

`reasoning_effort` on one identical prompt to `deep-reviewer`:

| effort | wall clock | completion tokens |
|---|---|---|
| `low` | 7.0 s | 321 |
| `medium` (the default here) | 5.8 s | 258 |
| `high` | 20.3 s | 1003 |

A real editor turn measured 23.3k prompt tokens in and 11.4k out: 43 s of prefill
and 243 s of decode, about five minutes, of which **85% was hidden reasoning
tokens nobody reads**. That is why `deep-reviewer` runs at `medium` rather than
the design document's `high`. Ask for more per request when a review deserves it —
`llama-server` honours `"chat_template_kwargs": {"reasoning_effort": "high"}` in
the request body, which overrides the server default.

Drive Agent mode from `interactive`. It answered the same tool-call test in 2.4 s
against `deep-reviewer`'s 20.7 s, and the reasoning is wasted on mechanical edits.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol.

Last review: 2026.08.04

Back to [Yuruna](https://yuruna.com)
