# Shared local code-review server on a Ryzen AI Max+ "Strix Halo" (Debian 13)

Build one box on the LAN that several developer machines point at for local code
analysis — dead code, function consolidation, vulnerability review — with no code
leaving the network.

**Audience:** an operator with `sudo` on the Halo box who is comfortable with
systemd, nginx and building C++ from source.

**Target of this guide**

| | |
|---|---|
| Server hardware | AMD Ryzen AI Max+ 395 "Strix Halo", 128 GB unified LPDDR5X |
| Server OS | Debian 13 (trixie) |
| Inference engines | llama.cpp + llama-swap (OpenAI API) **and** Ollama (native API) |
| Front door | nginx — TLS, per-user tokens, LAN allowlist |
| Clients | **Local Code AI** (this repo's extension), Continue, aider, CI scripts |

---

## 0. Read this first — two facts that shape everything

### 0.1 The NPU is not usable for this

Strix Halo markets "50 TOPS" from the XDNA 2 NPU. On Linux there is no production
LLM path to it: AMD's NPU LLM stack (Ryzen AI SW / Lemonade) is Windows-first, and
the `amdxdna` driver plus XRT get you matmul offload for bespoke ONNX graphs, not a
llama.cpp backend. **Plan the box around the iGPU and the memory bus.** If a future
release changes this it will be additive; nothing below has to be redone.

The parts that actually do work for you:

- **Radeon 8060S iGPU**, 40 RDNA 3.5 CUs, LLVM target **`gfx1151`**.
- **256-bit LPDDR5X-8000 → ~256 GB/s theoretical**, roughly 210–230 GB/s achievable.
- **128 GB unified memory**, most of which the GPU can address. This is the reason
  the box is interesting: it runs models that need a $30k discrete-GPU rig, just
  slower.

Token generation is bandwidth-bound: **tok/s ≈ achievable bandwidth ÷ bytes read per
token**. That single relation explains every model choice in §5 — Mixture-of-Experts
models win here because only a fraction of their weights are read per token.

### 0.2 Your "Local Code" extension needs the *Ollama* API, not OpenAI's

This repo's extension talks to the Ollama native API and nothing else:

| Call | Where |
|---|---|
| `GET /api/version` | [model.js:34](../extension/local-code-ai/model.js#L34) |
| `GET /api/tags` | [model.js:45](../extension/local-code-ai/model.js#L45) |
| `GET /api/ps` | [model.js:53](../extension/local-code-ai/model.js#L53) |
| `POST /api/show` | [model.js:61](../extension/local-code-ai/model.js#L61) |
| `POST /api/generate` (load / `keep_alive: 0` unload) | [model.js:83](../extension/local-code-ai/model.js#L83), [model.js:99](../extension/local-code-ai/model.js#L99) |
| `POST /api/chat` (streaming, tools) | [chat.js:215](../extension/local-code-ai/chat.js#L215) |

llama.cpp's `llama-server` and llama-swap serve **only** `/v1/*` (OpenAI-compatible).
They do not implement `/api/tags` or `/api/ps`, so "Check Setup" and the chat panel
would both fail against a llama-swap-only server.

Two more properties of the current code matter for remote use:

- `fetchJson` sends **no `Authorization` header**
  ([model.js:27-31](../extension/local-code-ai/model.js#L27-L31)), so a bearer-token
  gate in front of `/api/*` locks out your own extension. §8 handles `/api/*` with a
  source-IP allowlist instead; §11 has the ~15-line patch if you want tokens there too.
- `localHostPort()` returns `null` for any non-loopback endpoint
  ([model.js:72-79](../extension/local-code-ai/model.js#L72-L79)), so **Start Model**
  and **Stop Model** correctly refuse to manage a remote server. That is by design —
  on this build the server's lifecycle belongs to systemd (§9).

**Therefore: run both engines.** They split cleanly by role and the 128 GB pool has
room for both.

```
                     Halo box (halo.lan)
   ┌───────────────────────────────────────────────────────────┐
   │  nginx :8443  (TLS, tokens, LAN allowlist, long timeouts) │
   │        │                                                  │
   │        ├── /api/*  ──►  Ollama        127.0.0.1:11434     │
   │        │                └─ localcoder  (fast, resident)   │
   │        │                                                  │
   │        └── /v1/*   ──►  llama-swap    127.0.0.1:8081      │
   │                         ├─ deep-reviewer  (heavy, swaps)  │
   │                         ├─ second-opinion (heavy, swaps)  │
   │                         ├─ code-embed     (resident)      │
   │                         └─ code-fim       (resident)      │
   └───────────────────────────────────────────────────────────┘
        ▲                    ▲                      ▲
   Local Code AI        Continue / aider        CI + batch
   (Ollama API)         (OpenAI API)            review scripts
```

---

## 1. Base OS preparation

### 1.1 Firmware, kernel, repositories

Debian 13 ships kernel 6.12. Strix Halo works there, but display and compute
stability improved materially after 6.14 — **take the backports kernel.**

```bash
sudo tee /etc/apt/sources.list.d/backports.sources >/dev/null <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

# make sure non-free-firmware is on the main entry too
grep -q non-free-firmware /etc/apt/sources.list.d/debian.sources \
  || sudo sed -i 's/^Components: .*/& non-free-firmware/' /etc/apt/sources.list.d/debian.sources

sudo apt update
sudo apt install -t trixie-backports -y linux-image-amd64 linux-headers-amd64 firmware-amd-graphics
sudo apt install -y firmware-linux-nonfree
```

Reboot, then confirm the kernel is new enough and the iGPU came up:

```bash
uname -r
lspci -nn | grep -i 'VGA\|Display'
sudo dmesg | grep -iE 'amdgpu.*(gfx11|firmware|GTT|VRAM)' | head -30
```

You are looking for `amdgpu` binding and an IP discovery line consistent with GFX
11.5. If `amdgpu` fails to load, you are missing firmware — fix that before anything
else.

### 1.2 UEFI: give the GPU a *small* fixed carve-out

Counter-intuitive but correct on Linux: in UEFI set **UMA Frame Buffer Size /
Dedicated Graphics Memory to 512 MB** (or `Auto`), *not* to 96 GB.

A large fixed UMA carve-out is permanently stolen from the OS. On Linux the amdgpu
driver reaches the rest of RAM through **GTT** (Graphics Translation Table), which is
allocated on demand and returned when freed. The Vulkan backend and ROCm 6.4.1+ both
allocate happily from GTT on `gfx1151`.

The one exception: if an older ROCm build refuses to allocate past `VRAM`, raise UMA
to 64–96 GB as a fallback. Test before you commit to it — you lose that RAM to
everything else on the box.

### 1.3 Let the GPU address ~112 GiB

Add kernel parameters so GTT and the TTM page limit are explicit rather than
whatever the kernel's heuristic picks:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amdgpu.gttsize=114688 ttm.pages_limit=29360128 ttm.page_pool_size=29360128"/' /etc/default/grub
sudo update-grub
sudo reboot
```

The arithmetic, so you can retune for a different split:

- `amdgpu.gttsize` is in **MiB** → `114688` = 112 GiB.
- `ttm.pages_limit` is in **4 KiB pages** → `112 GiB × 256 pages/MiB = 29,360,128`.
- Keep the two consistent. Leaving ~16 GiB for the OS, page cache and the review
  tooling is the point of stopping at 112.

Verify after reboot:

```bash
# GTT the driver actually offers (bytes)
for c in /sys/class/drm/card*/device/mem_info_gtt_total; do echo "$c: $(cat "$c")"; done
# 120259084288 == 112 GiB
```

### 1.4 Groups, users, storage

```bash
sudo apt install -y vulkan-tools mesa-vulkan-drivers libvulkan1 jq curl git

# service account that owns the engines and the weights
sudo useradd -r -m -d /srv/llm -s /usr/sbin/nologin llm
sudo usermod -aG render,video llm

# your own account, for benchmarking by hand
sudo usermod -aG render,video "$USER"

# weights live on their own path; expect 200-300 GB
sudo install -d -o llm -g llm /srv/models/gguf /srv/models/ollama /srv/llm/logs

# confirm the GPU is visible through Vulkan
vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverName'
```

Expect `Radeon 8060S Graphics (RADV GFX1151)`. If `vulkaninfo` finds no device,
you are not in `render`/`video` (log out and back in) or `mesa-vulkan-drivers` is
missing.

---

## 2. Choosing the GPU backend: Vulkan first, ROCm if it measures better

Debian is **not** a distribution AMD supports with `amdgpu-install`. You have two
sane options and should pick with a benchmark, not with a preference.

| | **Vulkan (RADV)** | **ROCm/HIP** |
|---|---|---|
| Install on Debian 13 | already done in §1.4 | container only (§2.2) |
| Token generation | very competitive on RDNA 3.5 | comparable |
| **Prompt processing** | good | **often meaningfully faster** |
| Risk | low | unsupported distro, image churn |

Prompt processing dominates code review — you push thousands of lines of source in
and get a few hundred tokens back. That is the one number worth measuring.

### 2.1 Build llama.cpp with the Vulkan backend

```bash
sudo apt install -y build-essential cmake git ccache pkg-config \
     libcurl4-openssl-dev libvulkan-dev glslc spirv-tools

sudo -u llm git clone https://github.com/ggml-org/llama.cpp /srv/llm/llama.cpp
cd /srv/llm/llama.cpp

sudo -u llm cmake -B build-vulkan \
  -DGGML_VULKAN=ON \
  -DLLAMA_CURL=ON \
  -DCMAKE_BUILD_TYPE=Release
sudo -u llm cmake --build build-vulkan --config Release -j"$(nproc)"
```

> If `apt` cannot find `glslc`, it comes from Google's *shaderc*; check
> `apt-cache search glslc` and `apt-cache search shaderc`. The Vulkan backend will
> not compile without it.

Smoke test and get your baseline numbers:

```bash
cd /srv/llm/llama.cpp
./build-vulkan/bin/llama-bench -m /srv/models/gguf/<some-model>.gguf -ngl 999 -p 4096 -n 128
```

Read the `pp4096` (prompt processing, tok/s) and `tg128` (generation, tok/s) rows.

### 2.2 Optional: ROCm 7 in a container, then compare

Only the kernel driver lives on the host; ROCm userspace stays in the image, which
sidesteps Debian's lack of official packages entirely.

```bash
sudo apt install -y podman
sudo podman run --rm -it \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups --security-opt seccomp=unconfined --ipc=host \
  -v /srv/models:/models:z \
  docker.io/rocm/dev-ubuntu-24.04:7.0-complete bash

# inside the container
rocminfo | grep -i gfx          # expect gfx1151
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
  cmake -S . -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
./build/bin/llama-bench -m /models/gguf/<same-model>.gguf -ngl 999 -p 4096 -n 128
```

If `rocminfo` reports `gfx1151` but HIP kernels fail with `hipErrorNoBinaryForGpu`,
export `HSA_OVERRIDE_GFX_VERSION=11.5.1` and retry.

**Decide on the `pp4096` delta.** If ROCm is not clearly ahead, stay on Vulkan — the
operational simplicity is worth real throughput. The rest of this guide assumes the
Vulkan binaries at `/srv/llm/llama.cpp/build-vulkan/bin`; if you chose ROCm, install
that build to the same path and add the environment variables to the unit in §9.

---

## 3. llama-swap

`llama-server` serves exactly one model. llama-swap fronts many: one port, one model
list, automatic load/unload, and **groups** so a small model can stay resident while
the heavyweights take turns. That last property is what makes 128 GB feel like more.

```bash
LS_VER=$(curl -fsSL https://api.github.com/repos/mostlygeek/llama-swap/releases/latest | jq -r .tag_name)
curl -fsSL "https://github.com/mostlygeek/llama-swap/releases/download/${LS_VER}/llama-swap_${LS_VER#v}_linux_amd64.tar.gz" \
  | sudo tar -xz -C /usr/local/bin llama-swap
sudo chmod 755 /usr/local/bin/llama-swap
llama-swap --version
```

---

## 4. Fetch the weights

```bash
sudo apt install -y python3-pip pipx
pipx install "huggingface_hub[cli]"

sudo -u llm -H bash -lc 'hf download <repo> --include "<pattern>" --local-dir /srv/models/gguf/<name>'
```

Downloads are 20–70 GB each; run them in `tmux` and check free space first.

---

## 5. The three models

Sized for 128 GB with ~112 GiB reachable by the GPU. Roles are chosen so the three
cover different failure modes — one fast, one deep, one from a different training
lineage for cross-checking.

> **Check for successors before you download.** This field moves quarterly. The
> *tiering logic* below — one small-active MoE for interactive work, one large MoE
> for depth, one from a different family for a second opinion — outlives any specific
> checkpoint. Swap names, keep the shape.

### Model 1 — `Qwen3-Coder-30B-A3B-Instruct` · interactive workhorse

- **License:** Apache 2.0 · **Repo:** `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`
- **Quant:** `UD-Q5_K_XL` ≈ 21 GB · **Context:** 256K native
- **Active parameters: 3.3 B of 30 B.** This is why it belongs here — a dense 30B
  reads ~10× more memory per token on the same bus.
- **Expect roughly 40–55 tok/s generation.**

The default for chat, in-editor edits, "explain this function", and every
interactive turn. Its 256K context swallows a mid-size module in one pass.

### Model 2 — `gpt-oss-120b` · deep reviewer

- **License:** Apache 2.0 · **Repo:** `ggml-org/gpt-oss-120b-GGUF`
- **Quant:** native MXFP4 ≈ 63 GB · **Context:** 128K
- **Active parameters: 5.1 B of 117 B.**
- **Expect roughly 25–40 tok/s generation.**

The vulnerability and architecture pass. Its adjustable reasoning effort is the
feature that matters: run it at `high` for security review, where you want it to
actually chase the taint path rather than pattern-match.

```
--jinja --chat-template-kwargs '{"reasoning_effort":"high"}'
```

### Model 3 — `GLM-4.5-Air` · second opinion

- **License:** MIT · **Repo:** `unsloth/GLM-4.5-Air-GGUF`
- **Quant:** `UD-Q4_K_XL` ≈ 70 GB · **Context:** 128K
- **Active parameters: 12 B of 106 B.**
- **Expect roughly 15–22 tok/s generation.**

Different lab, different data, different blind spots. Use it to re-review model 2's
findings: two independent models agreeing on a vulnerability is a far stronger signal
than one model asserting it twice. Its long-horizon agentic behavior also makes it
the better choice for multi-file consolidation work.

> **Lighter alternative:** `Devstral-Small-2507` (24 B dense, Apache 2.0, 128K) if you
> would rather have a repo-walking agent than a third heavyweight. It is ~14 GB and
> can stay resident, at ~10–13 tok/s.

### Two support models (not headline picks, but required)

| Model | Role | Size | Why |
|---|---|---|---|
| `Qwen3-Embedding-0.6B-GGUF` | `embed` | ~1.2 GB | Continue's `@codebase`, and any retrieval you build. Needs `--pooling last`. |
| `Qwen2.5-Coder-3B` (**base**, not instruct) | `autocomplete` | ~2 GB | Fill-in-the-middle. Instruct-tuned models are wrong for FIM. |

### Memory budget

| Resident | GB |
|---|---|
| Ollama: `localcoder` (Qwen3-Coder-30B Q5) + 64K KV × 4 slots | ~28 |
| llama-swap: embeddings + FIM | ~4 |
| llama-swap: **one** heavyweight (gpt-oss-120b *or* GLM-4.5-Air) | 63–70 |
| **Peak** | **~102 GB** |

Inside 112 GiB, with headroom. Note that the two heavyweights **cannot** be resident
together — that is exactly what the llama-swap group in §6 enforces.

---

## 6. Configure llama-swap

`/srv/llm/llama-swap.yaml` — owned by `llm`, mode `0640`.

```yaml
healthCheckTimeout: 900        # 70 GB off a cold page cache is slow
logLevel: info
startPort: 10001

macros:
  bin: "/srv/llm/llama.cpp/build-vulkan/bin/llama-server"
  common: >-
    --host 127.0.0.1 --port ${PORT}
    -ngl 999 --no-mmap -fa on
    --cache-type-k q8_0 --cache-type-v q8_0
    --metrics --jinja

models:

  interactive:
    name: "Qwen3-Coder 30B-A3B"
    cmd: |
      ${bin} ${common}
      -m /srv/models/gguf/qwen3-coder-30b/UD-Q5_K_XL.gguf
      -c 262144 --parallel 4
      --temp 0.15 --top-p 0.8 --top-k 20 --repeat-penalty 1.05
    aliases: ["qwen3-coder", "fast"]

  deep-reviewer:
    name: "gpt-oss-120b (high effort)"
    cmd: |
      ${bin} ${common}
      -m /srv/models/gguf/gpt-oss-120b/gpt-oss-120b-mxfp4.gguf
      -c 262144 --parallel 4
      --chat-template-kwargs {"reasoning_effort":"high"}
      --temp 0.2 --top-p 0.9
    aliases: ["review", "security"]
    ttl: 1800

  second-opinion:
    name: "GLM-4.5-Air"
    cmd: |
      ${bin} ${common}
      -m /srv/models/gguf/glm-4.5-air/UD-Q4_K_XL.gguf
      -c 131072 --parallel 2
      --temp 0.2 --top-p 0.9
    aliases: ["glm", "crosscheck"]
    ttl: 1800

  code-embed:
    name: "Qwen3-Embedding-0.6B"
    cmd: |
      ${bin} --host 127.0.0.1 --port ${PORT}
      -m /srv/models/gguf/qwen3-embed-0.6b/Q8_0.gguf
      -ngl 999 --embeddings --pooling last -c 32768 --parallel 8
    aliases: ["embed"]

  code-fim:
    name: "Qwen2.5-Coder-3B base (FIM)"
    cmd: |
      ${bin} --host 127.0.0.1 --port ${PORT}
      -m /srv/models/gguf/qwen2.5-coder-3b-base/Q6_K.gguf
      -ngl 999 -c 16384 --parallel 6 -fa on
    aliases: ["fim", "autocomplete"]

groups:
  # small models: always up, never evicted by a swap
  resident:
    swap: false
    exclusive: false
    persistent: true
    members: ["code-embed", "code-fim"]

  # heavyweights: strictly one at a time
  heavy:
    swap: true
    exclusive: false
    members: ["deep-reviewer", "second-opinion"]
```

Two things to understand here:

- **`swap: true` on `heavy`** is what keeps you inside the memory budget: requesting
  `second-opinion` unloads `deep-reviewer` first. The 60–90 s swap is the price of
  running two 100B-class models on one box.
- **`-c` is the *total* KV cache, divided across `--parallel` slots.** `-c 262144
  --parallel 4` gives four concurrent users 64K each — not four users with 256K.
  Size this against §10.

> llama-swap's schema evolves. Diff against `config.example.yaml` in the release you
> installed before assuming a key exists, and validate with
> `sudo -u llm llama-swap --config /srv/llm/llama-swap.yaml --watch-config` in the
> foreground once.

---

## 7. Ollama, for the Local Code AI extension

This is the half that makes *this repo's* extension work unmodified.

```bash
# read it before you run it
curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh
less /tmp/ollama-install.sh
sudo sh /tmp/ollama-install.sh
```

Override the packaged unit rather than editing it:

```bash
sudo install -d /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<'EOF'
[Service]
# loopback only - nginx is the only thing that may reach it
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_MODELS=/srv/models/ollama"

# shared box: several editors at once, model stays warm between them
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"

Environment="OLLAMA_CONTEXT_LENGTH=65536"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"

# only if ROCm rejects gfx1151
# Environment="HSA_OVERRIDE_GFX_VERSION=11.5.1"

SupplementaryGroups=render video
LimitMEMLOCK=infinity
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama
```

Create the `localcoder` alias the extension expects. This mirrors what
[local.code.ai.ps1:599-602](../local.code.ai.ps1#L599-L602) does on a workstation,
sized up for the Halo's memory:

```bash
sudo -u llm ollama pull qwen3-coder:30b

printf 'FROM qwen3-coder:30b\nPARAMETER num_ctx 65536\n' | sudo -u llm tee /srv/llm/Modelfile.localcoder
sudo -u llm ollama create localcoder -f /srv/llm/Modelfile.localcoder

sudo -u llm ollama list
curl -s http://127.0.0.1:11434/api/version | jq
```

> `OLLAMA_NUM_PARALLEL=4` with `num_ctx 65536` means Ollama reserves **4 × 64K** of
> KV cache. That is deliberate — it is what lets four developers hold independent
> conversations. Drop `num_ctx` to 32768 if you would rather have eight.

### Keeping the two engines out of each other's memory

Ollama and llama-swap each allocate independently; neither knows about the other.
Guardrails:

- `OLLAMA_MAX_LOADED_MODELS=1` — Ollama never holds more than `localcoder`.
- llama-swap's `heavy` group holds at most one big model.
- `OLLAMA_KEEP_ALIVE=30m` returns ~28 GB overnight and on quiet afternoons.

If you later add a second Ollama model, redo the arithmetic in §5. An out-of-memory
allocation on the GPU surfaces as a load failure or a silent fall back to CPU at
~2 tok/s, not as a clean error.

---

## 8. nginx: one front door for the whole LAN

Handles TLS, per-user tokens, source restriction, and the long-lived streaming
connections both APIs need.

```bash
sudo apt install -y nginx
```

### 8.1 Tokens

```bash
# one per human, plus one for CI - so you can revoke individually
for u in alice bob carol ci; do
  printf '%-8s %s\n' "$u" "lk_${u}_$(openssl rand -hex 24)"
done | sudo tee /root/llm-tokens.txt
sudo chmod 600 /root/llm-tokens.txt
```

`/etc/nginx/conf.d/llm-auth.conf`:

```nginx
# paste the generated values
map $http_authorization $llm_user {
    default                             "";
    "Bearer lk_alice_REPLACE_ME"        "alice";
    "Bearer lk_bob_REPLACE_ME"          "bob";
    "Bearer lk_carol_REPLACE_ME"        "carol";
    "Bearer lk_ci_REPLACE_ME"           "ci";
}

# adjust to your actual LAN
geo $lan_ok {
    default          0;
    127.0.0.1/32     1;
    192.168.1.0/24   1;
    10.0.0.0/8       1;
}

limit_conn_zone  $llm_user      zone=peruser:10m;
limit_req_zone   $binary_remote_addr zone=llmreq:10m rate=120r/m;

log_format llm '$remote_addr "$llm_user" $status $request_time "$request" $body_bytes_sent';
```

### 8.2 The site

`/etc/nginx/sites-available/llm`:

```nginx
upstream ollama    { server 127.0.0.1:11434; keepalive 8; }
upstream llamaswap { server 127.0.0.1:8081;  keepalive 8; }

server {
    listen 8443 ssl;
    http2 on;
    server_name halo.lan;

    ssl_certificate     /etc/nginx/tls/halo.crt;
    ssl_certificate_key /etc/nginx/tls/halo.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/llm.log llm;

    # a 70B review of a large file is a legitimately huge request body
    client_max_body_size 128m;
    client_body_timeout  300s;

    # token streaming dies without these
    proxy_http_version 1.1;
    proxy_set_header   Connection "";
    proxy_buffering    off;
    proxy_cache        off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # ---- Ollama native API: Local Code AI extension ----------------------
    # The extension sends no Authorization header (model.js fetchJson), so
    # this route is gated by source address only. Keep it on a trusted VLAN.
    location /api/ {
        if ($lan_ok = 0) { return 403; }
        limit_req zone=llmreq burst=40 nodelay;
        proxy_pass http://ollama;
    }

    # ---- OpenAI-compatible API: Continue, aider, CI ----------------------
    location /v1/ {
        if ($lan_ok = 0)   { return 403; }
        if ($llm_user = "") { return 401; }
        limit_conn peruser 2;
        limit_req  zone=llmreq burst=40 nodelay;
        proxy_pass http://llamaswap;
    }

    # ---- llama-swap operator UI: admin subnet only -----------------------
    location / {
        allow 192.168.1.0/24;
        deny  all;
        proxy_pass http://llamaswap;
    }
}
```

```bash
sudo ln -sf /etc/nginx/sites-available/llm /etc/nginx/sites-enabled/llm
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

### 8.3 TLS — pick the option that matches your fleet

**Option A (recommended): Tailscale.** You get a publicly-trusted certificate with
no internal CA to distribute, and roaming laptops keep working off-LAN.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo tailscale cert --cert-file /etc/nginx/tls/halo.crt \
                    --key-file  /etc/nginx/tls/halo.key \
                    "$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"
```

Set `server_name` to the `*.ts.net` name and add the tailnet CGNAT range
(`100.64.0.0/10`) to the `geo` block.

**Option B: internal CA.** Works, but note the trap — **VS Code's extension host is
Node, and Node does not read the OS trust store.** Every client machine needs
`NODE_EXTRA_CA_CERTS=/path/to/ca.crt` exported *before VS Code launches*, or the
extension's `fetch` fails with `UNABLE_TO_VERIFY_LEAF_SIGNATURE` while `curl` on the
same box works fine.

**Option C: plain HTTP on a trusted VLAN.** Change `listen 8443 ssl` to `listen 8080`,
drop the `ssl_*` lines. Defensible for an isolated developer VLAN; the token still
gates `/v1/`. Understand that tokens then cross the wire in clear text.

### 8.4 Firewall

```bash
sudo apt install -y nftables
sudo tee /etc/nftables.conf >/dev/null <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    tcp dport 22 accept
    ip saddr { 192.168.1.0/24, 10.0.0.0/8 } tcp dport 8443 accept
    ip protocol icmp accept
  }
}
EOF
sudo systemctl enable --now nftables
```

11434 and 8081 are never exposed — both engines bind loopback.

---

## 9. systemd

Ollama's unit came with its installer. Add llama-swap:

`/etc/systemd/system/llama-swap.service`:

```ini
[Unit]
Description=llama-swap (llama.cpp model router)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=llm
Group=llm
SupplementaryGroups=render video
WorkingDirectory=/srv/llm
ExecStart=/usr/local/bin/llama-swap --config /srv/llm/llama-swap.yaml --listen 127.0.0.1:8081
Restart=always
RestartSec=5

# 70 GB models must not be paged out mid-generation
LimitMEMLOCK=infinity
LimitNOFILE=65536
OOMScoreAdjust=-500

# uncomment for a ROCm build
# Environment="HSA_OVERRIDE_GFX_VERSION=11.5.1"
# Environment="ROCBLAS_USE_HIPBLASLT=1"

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/srv/llm /srv/models

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now llama-swap
systemctl status llama-swap ollama nginx --no-pager
```

End-to-end check from a client machine:

```bash
TOKEN=lk_alice_REPLACE_ME
HOST=https://halo.lan:8443

curl -s "$HOST/api/version" | jq                          # Ollama route, no token
curl -s "$HOST/api/tags" | jq -r '.models[].name'          # must list localcoder
curl -s -H "Authorization: Bearer $TOKEN" "$HOST/v1/models" | jq -r '.data[].id'
curl -s "$HOST/v1/models"                                  # must return 401
```

---

## 10. Client configuration

### 10.1 Local Code AI (this repo's extension)

Two settings, and everything else keeps working:

```jsonc
// .vscode/settings.json, or User settings on each machine
{
  "localCodeAI.endpoint": "https://halo.lan:8443",   // NO trailing slash
  "localCodeAI.model": "localcoder",
  "localCodeAI.chatTools": true,
  "localCodeAI.temperature": 0.15,
  "localCodeAI.timeoutSeconds": 900,     // shared box: you may queue behind others
  "localCodeAI.maxFileKB": 512,          // 64K context is plenty for large files
  "localCodeAI.chatMaxReadKB": 256,
  "localCodeAI.chatContextFileLimit": 800
}
```

The endpoint is joined with string concatenation
([model.js:35](../extension/local-code-ai/model.js#L35)), so a trailing slash yields
`//api/version` and a 404. Leave it off.

**What changes when the endpoint is remote:**

| Command | Behavior |
|---|---|
| Open Chat / Refactor & Format | work normally against the Halo box |
| Check Setup | probes the remote server and model correctly |
| **Start Model** | **no-op** — `localHostPort()` returns `null` for a remote host ([model.js:72-79](../extension/local-code-ai/model.js#L72-L79)) |
| **Stop Model** | **no-op**, same reason |

That is the right behavior: neither command should spawn a stray local server or
kill someone else's session. The Halo box is managed with
`sudo systemctl restart ollama`.

The formatter toolchain (gofumpt, rustfmt, prettier, PSScriptAnalyzer) still runs
**locally on each client** — only inference moved. Keep running
`local.code.ai.ps1 -SkipModel` on the workstations to install formatters without
pulling weights they no longer need.

### 10.2 Continue

`~/.continue/config.yaml`:

```yaml
name: halo-review
version: 1.0.0
schema: v1

models:
  - name: Fast (Qwen3-Coder 30B)
    provider: openai
    model: interactive
    apiBase: https://halo.lan:8443/v1
    apiKey: lk_alice_REPLACE_ME
    roles: [chat, edit, apply]
    defaultCompletionOptions:
      contextLength: 65536
      maxTokens: 8192
      temperature: 0.15

  - name: Deep review (gpt-oss-120b)
    provider: openai
    model: deep-reviewer
    apiBase: https://halo.lan:8443/v1
    apiKey: lk_alice_REPLACE_ME
    roles: [chat, edit]
    defaultCompletionOptions:
      contextLength: 65536
      maxTokens: 16384
      temperature: 0.2

  - name: Cross-check (GLM-4.5-Air)
    provider: openai
    model: second-opinion
    apiBase: https://halo.lan:8443/v1
    apiKey: lk_alice_REPLACE_ME
    roles: [chat]
    defaultCompletionOptions:
      contextLength: 65536

  - name: Autocomplete
    provider: openai
    model: code-fim
    apiBase: https://halo.lan:8443/v1
    apiKey: lk_alice_REPLACE_ME
    roles: [autocomplete]
    useLegacyCompletionsEndpoint: true

  - name: Embeddings
    provider: openai
    model: code-embed
    apiBase: https://halo.lan:8443/v1
    apiKey: lk_alice_REPLACE_ME
    roles: [embed]

context:
  - provider: code
  - provider: diff
  - provider: codebase
  - provider: problems
```

Autocomplete needs the raw completions endpoint, not chat — hence
`useLegacyCompletionsEndpoint: true`. Continue's YAML schema shifts between minor
versions; if a key is rejected, check the version's docs rather than fighting it.

Ship the team's shared *rules and prompts* in the repo (`.continue/rules/*.md`,
`.continue/prompts/*.md`) and keep only `apiKey` per-user.

### 10.3 Anything else OpenAI-compatible

```bash
export OPENAI_BASE_URL=https://halo.lan:8443/v1
export OPENAI_API_KEY=lk_alice_REPLACE_ME

aider --model openai/deep-reviewer --no-auto-commits
```

---

## 11. Optional: teach the extension to send a token

If you want `/api/*` behind the same token gate as `/v1/*` rather than an IP
allowlist, the change is small. Add a setting to
[package.json](../extension/local-code-ai/package.json):

```jsonc
"localCodeAI.apiKey": {
  "type": "string",
  "default": "",
  "description": "Bearer token sent to a remote server. Empty = no Authorization header (local Ollama)."
}
```

Then a helper in [model.js](../extension/local-code-ai/model.js), used by both
`fetchJson` and the `/api/chat` call at
[chat.js:215](../extension/local-code-ai/chat.js#L215):

```js
// Bearer token for a shared remote server; empty for a local Ollama, which
// has no auth of its own.
function authHeaders(cfg) {
  return cfg && cfg.apiKey ? { Authorization: `Bearer ${cfg.apiKey}` } : {};
}
```

Both call sites already build a `headers` object, so it merges in directly. Once
that ships, drop the `/api/` location in §8.2 to the same
`if ($llm_user = "") { return 401; }` rule as `/v1/`.

Store the token in VS Code's `SecretStorage` rather than settings if it must not
land in a synced `settings.json`.

---

## 12. Actually doing the code analysis

The part most guides skip. **Do not ask an LLM to find dead code.** It will
hallucinate call sites it cannot see and miss reflection, dynamic dispatch and
build-tag-gated code. Deterministic tools find *candidates* with real reachability
data; the model is for **triage, explanation and the fix** — the judgment work it is
actually good at.

### 12.1 Detector layer, matched to this repo's languages

```bash
# vulnerabilities and secrets - language agnostic
sudo apt install -y python3-venv
pipx install semgrep
curl -fsSL https://github.com/google/osv-scanner/releases/latest/download/osv-scanner_linux_amd64 \
  -o /usr/local/bin/osv-scanner && sudo chmod 755 /usr/local/bin/osv-scanner
# gitleaks, trivy: install from their releases

# dead code
npm  install -g knip jscpd            # JavaScript / TypeScript + clone detection
go   install golang.org/x/tools/cmd/deadcode@latest
cargo install cargo-machete           # unused Rust dependencies
pwsh -c 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
```

`jscpd` is the consolidation workhorse — it finds duplicated blocks *across*
languages, which is exactly the input for "should these become one function?".

### 12.2 Triage script

`/usr/local/bin/halo-review` — runs detectors, sends each finding with its
surrounding code to the deep reviewer, emits Markdown.

```bash
#!/usr/bin/env bash
# Detector output -> Halo review server -> triaged Markdown.
set -euo pipefail

REPO="${1:-.}"
HOST="${HALO_HOST:-https://halo.lan:8443}"
TOKEN="${HALO_TOKEN:?export HALO_TOKEN first}"
MODEL="${HALO_MODEL:-deep-reviewer}"
OUT="${REPO}/.halo-review"
mkdir -p "$OUT"

ask() {  # ask <system> <user>  -> assistant text
  jq -n --arg m "$MODEL" --arg s "$1" --arg u "$2" \
     '{model:$m, temperature:0.15, max_tokens:4096,
       messages:[{role:"system",content:$s},{role:"user",content:$u}]}' \
  | curl -sS --max-time 1800 "$HOST/v1/chat/completions" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d @- \
  | jq -r '.choices[0].message.content'
}

echo "==> detectors"
( cd "$REPO" && semgrep --config auto --json --quiet ) > "$OUT/semgrep.json" || true
( cd "$REPO" && osv-scanner --format json -r . )       > "$OUT/osv.json"     || true
( cd "$REPO" && jscpd --reporters json --output "$OUT" --silent . )          || true
( cd "$REPO" && knip --reporter json )                 > "$OUT/knip.json"    || true

echo "==> triage"
SYS='You are a senior security and maintainability reviewer. You are given one
static-analysis finding plus the surrounding source. Decide: TRUE POSITIVE,
FALSE POSITIVE, or NEEDS HUMAN. State the concrete exploit or breakage path in
one sentence - if you cannot state one, it is not a true positive. Then give a
minimal patch. Be terse. Never invent code you were not shown.'

: > "$OUT/report.md"
jq -c '.results[]? | {path:.path, line:.start.line, rule:.check_id, msg:.extra.message}' \
   "$OUT/semgrep.json" 2>/dev/null | while read -r f; do
  P=$(jq -r .path <<<"$f"); L=$(jq -r .line <<<"$f")
  SNIP=$(sed -n "$((L>25?L-25:1)),$((L+25))p" "$REPO/$P" 2>/dev/null || true)
  {
    printf '\n## %s:%s — %s\n\n' "$P" "$L" "$(jq -r .rule <<<"$f")"
    ask "$SYS" "$(printf 'Finding: %s\n\nFile %s around line %s:\n```\n%s\n```' \
                  "$(jq -r .msg <<<"$f")" "$P" "$L" "$SNIP")"
  } >> "$OUT/report.md"
done

echo "==> $OUT/report.md"
```

```bash
sudo install -m 755 halo-review /usr/local/bin/halo-review
export HALO_TOKEN=lk_ci_REPLACE_ME
halo-review ~/src/myproject
```

### 12.3 Whole-repo passes

For questions that need the *whole* repo rather than one finding — "which of these
four helpers should be one function?" — pack it and use the 256K context:

```bash
npx repomix --style markdown --output /tmp/repo.md ~/src/myproject
wc -c /tmp/repo.md          # ~4 chars/token; stay under ~800 KB for 256K ctx
```

Then send `/tmp/repo.md` with one of these. Add them to
[prompts.txt](../prompts.txt) so the chat panel has them one paste away.

**Dead code — candidates only, evidence required**

> You have the full source of a repository. List every symbol you believe is
> unreachable from any entry point (main, exported API, test, CLI command, build
> script, or reflective/dynamic call). For each: the symbol, its file:line, the
> entry points you checked, and a confidence of high/medium/low. Mark **low** for
> anything reachable by reflection, code generation, a build tag, a plugin
> mechanism, or a string-keyed dispatch table. Do not propose deletions — produce a
> candidate list a static tool can verify.

**Consolidation**

> Here are N functions flagged as near-duplicates by a clone detector. For each
> group: (1) what genuinely differs, (2) whether one function with parameters is
> better than N, or whether the duplication is intentional decoupling, (3) if
> consolidation wins, the merged signature and implementation, and every call site
> that must change. Reject the merge when the functions only look alike but serve
> different layers — say so explicitly.

**Vulnerabilities**

> Review this code for exploitable vulnerabilities. For each: the vulnerability
> class, the exact **untrusted input → dangerous sink** path with file:line at each
> hop, why existing validation does not stop it, and a minimal patch. If you cannot
> trace a complete path from attacker-controlled input to the sink, do not report
> it. Order by exploitability, not by CWE severity. Consider: injection, path
> traversal, deserialization, TOCTOU, authz gaps, secrets in source, unsafe
> defaults.

Each prompt forces the model to show reachability or a taint path. That is what
converts a plausible-sounding list into one you can act on.

### 12.4 Cross-checking

For security findings you intend to act on, re-run them through
`second-opinion` (GLM-4.5-Air) with the finding *and* the code, asking it to refute:

```bash
HALO_MODEL=second-opinion halo-review ~/src/myproject
```

Two models from different labs agreeing is a much stronger signal than one model
asserting twice. Where they disagree, a human looks.

---

## 13. Operations

### Watching the box

```bash
sudo apt install -y btop
# amdgpu_top gives per-engine and VRAM/GTT breakdown; grab the .deb from
# https://github.com/Umio-Yasuno/amdgpu_top/releases
amdgpu_top

journalctl -u llama-swap -f
journalctl -u ollama -f
tail -f /var/log/nginx/llm.log      # who is using what, and how long it took
```

llama-swap's own UI is on `https://halo.lan:8443/` (admin subnet only, §8.2) — it
shows which model is loaded, live logs and per-model request counts.

### Sizing for the number of developers

`-c` is the total KV cache; `--parallel N` splits it. Pick from actual use:

| Concurrent users | `--parallel` | `-c` | Per-user context |
|---|---|---|---|
| 2 heavy reviewers | 2 | 262144 | 128K |
| 4 mixed | 4 | 262144 | 64K |
| 8 light chat | 8 | 262144 | 32K |

Beyond `--parallel`, requests queue inside `llama-server` — they do not fail, they
wait. This is why `localCodeAI.timeoutSeconds` is raised to 900 in §10.1.

Batching is a real win on this hardware: four concurrent users do **not** each get a
quarter of solo throughput. Prompt processing especially amortizes well.

### Expected numbers

Measure your own with `llama-bench`; treat these as a sanity range, not a spec:

| Model | Prompt processing | Generation |
|---|---|---|
| Qwen3-Coder-30B-A3B Q5 | 600–900 tok/s | 40–55 tok/s |
| gpt-oss-120b MXFP4 | 400–700 tok/s | 25–40 tok/s |
| GLM-4.5-Air Q4 | 250–450 tok/s | 15–22 tok/s |

A 2,000-line file is roughly 25K tokens: ~30–60 s to ingest on the deep reviewer
before the first output token. Set expectations with the team accordingly — this box
is excellent at *thorough* and mediocre at *snappy*.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ggml_vulkan: No devices found` | user not in `render`/`video`, or no `mesa-vulkan-drivers` | §1.4, then re-login |
| Model loads, ~2 tok/s | running on CPU | `-ngl 999` missing, or GPU alloc failed — check `journalctl` |
| `hipErrorNoBinaryForGpu` | ROCm build without gfx1151 | `HSA_OVERRIDE_GFX_VERSION=11.5.1` |
| `HSA_STATUS_ERROR_OUT_OF_RESOURCES` | GTT too small | recheck §1.3 arithmetic; try `iommu=pt`, then `amd_iommu=off` |
| Heavyweight fails to load, small ones fine | both engines resident at once | `OLLAMA_MAX_LOADED_MODELS=1`; verify the `heavy` group has `swap: true` |
| Extension: "Ollama not reachable" | trailing slash on endpoint, or `/api/` route/`geo` block | `curl $HOST/api/version` from the client |
| Extension works, Continue gets 401 | token not in the `map` | check `/var/log/nginx/llm.log` for an empty `$llm_user` |
| Reply truncates mid-stream | nginx buffering or timeout | `proxy_buffering off`, `proxy_read_timeout 3600s` |
| `UNABLE_TO_VERIFY_LEAF_SIGNATURE` | Node ignores the OS trust store | `NODE_EXTRA_CA_CERTS` before launching VS Code (§8.3 B) |
| First request after idle is very slow | model was evicted | expected — raise `ttl` / `OLLAMA_KEEP_ALIVE` |

### Maintenance

- Rebuild llama.cpp monthly; the Vulkan backend gains RDNA 3.5 performance steadily.
  Keep the previous `build-vulkan` directory until the new one benchmarks clean.
- Re-run `llama-bench` after each rebuild with a fixed model and record it. It is the
  only way to notice a regression before your users do.
- Rotate tokens by editing the `map` and `nginx -s reload`. No restart, no dropped
  model.
- `apt upgrade` on the backports kernel can break `amdgpu`. Keep the previous kernel
  installed and verify the GPU after every kernel change.

---

## 14. What this setup deliberately does not do

- **No authentication on `/api/*` by default.** It is a source-IP allowlist, because
  the extension cannot send a token today. On an untrusted network, do §11 first.
- **No multi-tenancy isolation.** Everyone shares one KV cache pool and one queue. A
  developer who pastes a 200K-token repo dump will slow everyone down. The
  `limit_conn peruser 2` in §8.2 is the only backstop.
- **No prompt or response logging.** nginx logs metadata only (§8.1's `llm` format).
  If you need audit trails of the code being reviewed, add it deliberately and tell
  the team — silently logging colleagues' source is the sort of thing that ends
  local-AI programs.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.

Last review: 2026.08.04

Back to [Yuruna](https://yuruna.com)
