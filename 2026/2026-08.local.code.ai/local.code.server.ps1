<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42a1e0c5-7b64-4e29-9d3f-8c15b0d2a7e6
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 by Alisson Sol.
.TAGS local-ai llama-swap llama-cpp continue vscode strix-halo
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    Local Code AI server - serves the review models over an OpenAI-compatible API
    for the Continue.continue VS Code extension.

.DESCRIPTION
    Turns an AMD Ryzen AI Max+ "Strix Halo" box (Debian 13 / Linux x64) into a shared
    code-review inference server, entirely inside the CURRENT FOLDER. Nothing is
    installed system-wide, no sudo is required, and no system service is created.

    What it does, in order:
      1. Platform checks ........ Linux x64 gate, then advisory checks for memory,
                                  the amdgpu render node, render/video group
                                  membership, a Vulkan loader and free disk space.
      2. Engine ................. downloads the prebuilt llama.cpp Vulkan build and
                                  the llama-swap release binary into .\bin. Re-runs
                                  upgrade them when a newer release exists. It then
                                  asks llama.cpp which GPUs it can see and stops if
                                  the answer is none, because CPU-only inference on
                                  these models is not worth a 145 GiB download.
      3. Models ................. downloads the five models from
                                  docs\ryzen-ai-halo-review-server.md into .\models
                                  (about 145 GiB in total). Downloads resume, and a
                                  file is re-fetched only when its upstream content
                                  hash changed.
      4. Configuration .......... generates .\run\llama-swap.yaml with the model
                                  roles, contexts and memory groups from the design
                                  document.
      5. Serving ................ starts llama-swap detached in the background and
                                  prints the URL to paste into local.code.client.ps1.

    Idempotent: re-running updates the engine and any changed weights, leaves an
    already-healthy server running, and restarts it only when the configuration
    changed. When downloads are impossible (no Internet, upstream unreachable) it
    logs the reason and serves whatever is already on disk.

    Models served (roles as used by Continue):

      interactive     Qwen3-Coder-30B-A3B-Instruct UD-Q5_K_XL   chat / edit / apply
      deep-reviewer   gpt-oss-120b MXFP4                        chat / edit
      second-opinion  GLM-4.5-Air UD-Q4_K_XL                    chat
      code-embed      Qwen3-Embedding-0.6B Q8_0                 embed
      code-fim        Qwen2.5-Coder-3B (base) Q6_K              autocomplete

.PARAMETER Port
    TCP port for the OpenAI-compatible endpoint. Default: 8888.

.PARAMETER BindAddress
    Address llama-swap listens on. Default: 0.0.0.0 (reachable from the LAN).

.PARAMETER ModelsPath
    Folder for the weights. Default: .\models under the current folder.

.PARAMETER NoDownload
    Skip the download/update phase and serve the weights already on disk.

.PARAMETER Status
    Report whether the server is running, then exit.

.PARAMETER Stop
    Stop a running server, then exit.

.PARAMETER Restart
    Stop a running server before starting it again.

.PARAMETER FixGroups
    Add the current user to the 'render' and 'video' groups (needs sudo) and exit.
    Group membership only takes effect at login, so log out and back in afterwards.

.PARAMETER Yes
    Non-interactive: auto-accept all confirmation prompts.

.PARAMETER Force
    Proceed even when the free-disk check fails.

.EXAMPLE
    pwsh ./local.code.server.ps1

.EXAMPLE
    pwsh ./local.code.server.ps1 -Port 9000 -ModelsPath /srv/models/gguf

.EXAMPLE
    pwsh ./local.code.server.ps1 -Status

.NOTES
    Requires PowerShell 7+ (pwsh) on Linux x64. The client side is configured with
    local.code.client.ps1, which runs on Windows, macOS and Linux.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive console tool: colored status output is intentional. On PowerShell 7 Write-Host writes to the information stream and stays redirectable, and Write-Output would corrupt helper function return values.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'False positive: each of these parameters is consumed inside a function defined later in this script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Start-ServerProcess and Stop-ServerProcess are private helpers of an interactive script whose whole purpose is to start and stop the server; -WhatIf/-Confirm on them would only add noise.')]
[CmdletBinding()]
param(
    [int]$Port = 8888,
    [string]$BindAddress = '0.0.0.0',
    [string]$ModelsPath = '',
    [switch]$NoDownload,
    [switch]$Status,
    [switch]$Stop,
    [switch]$Restart,
    [switch]$FixGroups,
    [switch]$Yes,
    [switch]$Force
)

# --- PowerShell 7 gate (this file stays parseable by 5.1 so the message shows) ---
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'This script requires PowerShell 7+ (pwsh) for cross-platform support.' -ForegroundColor Red
    Write-Host 'Install it, then re-run:' -ForegroundColor Yellow
    Write-Host '    sudo apt install -y powershell   # or see https://aka.ms/powershell'
    Write-Host '    pwsh ./local.code.server.ps1'
    exit 1
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest dramatically faster

# Native exit codes are inspected explicitly below; do not let them throw.
$PSNativeCommandUseErrorActionPreference = $false

$script:UserAgent = 'LocalCodeAI-Server'
$script:CurrentUser = $env:USER
if ([string]::IsNullOrWhiteSpace($script:CurrentUser)) {
    try { $script:CurrentUser = ("$(& id -un)").Trim() } catch { $script:CurrentUser = '<user>' }
}

# =============================================================================
#  Console helpers
# =============================================================================
function Write-Step { param([string]$Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-Wrn { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Inf { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Bad { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }

function Confirm-Continue {
    param([string]$Prompt)
    if ($Yes) { return $true }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^[Yy]')
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    return "$Bytes B"
}

# =============================================================================
#  Platform gate and layout
# =============================================================================
function Test-ServerPlatform {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()
    if ((-not $IsLinux) -or ($architecture -ne 'x64')) {
        $current = 'unknown'
        if ($IsWindows) { $current = 'Windows' } elseif ($IsMacOS) { $current = 'macOS' } elseif ($IsLinux) { $current = 'Linux' }
        Write-Host ''
        Write-Bad "This server runs on Linux x64 only (detected: $current/$architecture)."
        Write-Host ''
        Write-Inf 'It targets an AMD Ryzen AI Max+ "Strix Halo" box on Debian 13, using the'
        Write-Inf 'prebuilt llama.cpp Vulkan binaries. See docs/ryzen-ai-halo-review-server.md.'
        Write-Host ''
        Write-Inf 'To use a server that is already running, configure this machine instead:'
        Write-Inf '    pwsh ./local.code.client.ps1'
        Write-Host ''
        exit 1
    }
}

Test-ServerPlatform

$script:Root = (Get-Location).Path
if ([string]::IsNullOrWhiteSpace($ModelsPath)) { $ModelsPath = Join-Path $script:Root 'models' }

$Paths = @{
    Root      = $script:Root
    Models    = [System.IO.Path]::GetFullPath($ModelsPath)
    Bin       = Join-Path $script:Root 'bin'
    Engine    = Join-Path $script:Root 'bin/llama.cpp'
    Run       = Join-Path $script:Root 'run'
    Config    = Join-Path $script:Root 'run/llama-swap.yaml'
    PidFile   = Join-Path $script:Root 'run/llama-swap.pid'
    Log       = Join-Path $script:Root 'run/llama-swap.log'
    Manifest  = Join-Path $script:Root 'run/models.json'
    ToolsFile = Join-Path $script:Root 'run/tools.json'
    SwapBin   = Join-Path $script:Root 'bin/llama-swap'
    ServerBin = Join-Path $script:Root 'bin/llama.cpp/llama-server'
}

# =============================================================================
#  Model catalog - the five models of docs/ryzen-ai-halo-review-server.md, Section 5.
#  Sizes are first-run estimates only; the real size and content hash come from
#  a HEAD against Hugging Face.
# =============================================================================
$script:Catalog = @(
    [pscustomobject]@{
        Id          = 'interactive'
        Title       = 'Qwen3-Coder 30B-A3B'
        Dir         = 'qwen3-coder-30b'
        Repo        = 'unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF'
        Files       = @('Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL.gguf')
        ApproxBytes = 21740305568
        CmdHead     = '${bin} ${common}'
        CmdTail     = @('-c 262144 --parallel 4',
            '--temp 0.15 --top-p 0.8 --top-k 20 --repeat-penalty 1.05')
        Aliases     = @('qwen3-coder', 'fast')
        Ttl         = 0
        Group       = 'chat'
    }
    [pscustomobject]@{
        Id          = 'deep-reviewer'
        Title       = 'gpt-oss-120b (high effort)'
        Dir         = 'gpt-oss-120b'
        Repo        = 'ggml-org/gpt-oss-120b-GGUF'
        Files       = @('gpt-oss-120b-MXFP4.gguf')
        ApproxBytes = 63387346208
        CmdHead     = '${bin} ${common}'
        CmdTail     = @('-c 262144 --parallel 4',
            '--chat-template-kwargs {"reasoning_effort":"high"}',
            '--temp 0.2 --top-p 0.9')
        Aliases     = @('review', 'security')
        Ttl         = 1800
        Group       = 'heavy'
    }
    [pscustomobject]@{
        Id          = 'second-opinion'
        Title       = 'GLM-4.5-Air'
        Dir         = 'glm-4.5-air'
        Repo        = 'unsloth/GLM-4.5-Air-GGUF'
        Files       = @('UD-Q4_K_XL/GLM-4.5-Air-UD-Q4_K_XL-00001-of-00002.gguf',
            'UD-Q4_K_XL/GLM-4.5-Air-UD-Q4_K_XL-00002-of-00002.gguf')
        ApproxBytes = 67721071872
        CmdHead     = '${bin} ${common}'
        CmdTail     = @('-c 131072 --parallel 2',
            '--temp 0.2 --top-p 0.9')
        Aliases     = @('glm', 'crosscheck')
        Ttl         = 1800
        Group       = 'heavy'
    }
    [pscustomobject]@{
        Id          = 'code-embed'
        Title       = 'Qwen3-Embedding-0.6B'
        Dir         = 'qwen3-embed-0.6b'
        Repo        = 'Qwen/Qwen3-Embedding-0.6B-GGUF'
        Files       = @('Qwen3-Embedding-0.6B-Q8_0.gguf')
        ApproxBytes = 639150592
        CmdHead     = '${bin} --host 127.0.0.1 --port ${PORT}'
        CmdTail     = @('-ngl 999 --embeddings --pooling last -c 32768 --parallel 8')
        Aliases     = @('embed')
        Ttl         = 0
        Group       = 'resident'
    }
    [pscustomobject]@{
        Id          = 'code-fim'
        Title       = 'Qwen2.5-Coder-3B base (FIM)'
        Dir         = 'qwen2.5-coder-3b-base'
        Repo        = 'bartowski/Qwen2.5-Coder-3B-GGUF'
        Files       = @('Qwen2.5-Coder-3B-Q6_K.gguf')
        ApproxBytes = 2538159200
        CmdHead     = '${bin} --host 127.0.0.1 --port ${PORT}'
        CmdTail     = @('-ngl 999 -c 16384 --parallel 6 -fa on')
        Aliases     = @('fim', 'autocomplete')
        Ttl         = 0
        Group       = 'resident'
    }
)

# Group definitions, keyed by the Group field above. Memory arithmetic is in
# Section 5 of the design document: chat (~28 GB) and resident (~4 GB) stay loaded,
# and the two heavyweights (63-70 GB) take turns.
$script:GroupSpec = [ordered]@{
    chat     = @{ Swap = $false; Exclusive = $false; Persistent = $true }
    resident = @{ Swap = $false; Exclusive = $false; Persistent = $true }
    heavy    = @{ Swap = $true; Exclusive = $false; Persistent = $false }
}

# =============================================================================
#  Small utilities
# =============================================================================
function Find-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

# Quote a string for /bin/sh so paths with spaces or quotes survive.
function ConvertTo-ShellArgument {
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-HttpHeaderValue {
    param($Headers, [string]$Name)
    if ($null -eq $Headers) { return $null }
    $values = $null
    if ($Headers.TryGetValues($Name, [ref]$values)) { return ($values | Select-Object -First 1) }
    return $null
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{} }
    try { return (Get-Content -Raw -Path $Path | ConvertFrom-Json -AsHashtable) }
    catch {
        Write-Wrn "could not read $Path ($($_.Exception.Message)); starting from scratch"
        return @{}
    }
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-FreeDiskGB {
    param([string]$Path)
    try {
        $probe = $Path
        while ($probe -and -not (Test-Path $probe)) { $probe = Split-Path -Parent $probe }
        if (-not $probe) { return -1 }
        $output = & df -Pk $probe 2>$null
        if ($LASTEXITCODE -eq 0 -and $output.Count -ge 2) {
            $fields = ($output[-1] -split '\s+')
            return [math]::Round(([int64]$fields[3] * 1024) / 1GB, 1)
        }
    }
    catch { Write-Debug "df failed for '$Path': $_" }
    return -1
}

function Get-TotalMemoryGB {
    try {
        $line = Get-Content /proc/meminfo | Select-String '^MemTotal:'
        $kb = [int64](($line -replace '[^\d]', ''))
        return [math]::Round($kb / 1MB, 1)
    }
    catch { return 0 }
}

# =============================================================================
#  1) Advisory checks
# =============================================================================
function Test-Prerequisite {
    Write-Step 'Checking the machine'

    $memoryGB = Get-TotalMemoryGB
    if ($memoryGB -le 0) { Write-Wrn 'could not read /proc/meminfo' }
    elseif ($memoryGB -lt 100) {
        Write-Wrn "$memoryGB GB of memory: the generated contexts assume a 128 GB box"
        Write-Inf 'lower -c / --parallel in run/llama-swap.yaml, or expect load failures'
    }
    else { Write-Ok "memory: $memoryGB GB" }

    # What matters is whether this user can actually open the render node, not which
    # groups are listed: a 0666 node or an ACL grants access without 'render', and
    # being in 'render' does not help if the node is owned differently.
    $renderNodes = @(Get-ChildItem -Path '/dev/dri' -Filter 'renderD*' -ErrorAction SilentlyContinue)
    if ($renderNodes.Count -eq 0) {
        Write-Wrn 'no /dev/dri/renderD* node: the GPU is not visible, inference would run on CPU'
    }
    else {
        $node = $renderNodes[0].FullName
        $quoted = ConvertTo-ShellArgument $node
        & /bin/sh -c "test -r $quoted && test -w $quoted"
        if ($LASTEXITCODE -eq 0) { Write-Ok "render node: $node (readable and writable)" }
        else {
            Write-Wrn "$node exists but this user cannot open it - llama.cpp would fall back to CPU"
            Write-Inf "fix with:  sudo usermod -aG render,video $($script:CurrentUser)   (then log out and back in)"
            Write-Inf 'or re-run this script with -FixGroups to do that for you'
        }
    }

    $loaderPaths = @('/usr/lib/x86_64-linux-gnu/libvulkan.so.1', '/usr/lib/libvulkan.so.1', '/usr/lib64/libvulkan.so.1')
    $haveLoader = @($loaderPaths | Where-Object { Test-Path $_ }).Count -gt 0
    if (-not $haveLoader -and -not (Find-CommandPath 'vulkaninfo')) {
        Write-Wrn 'no Vulkan loader found: sudo apt install -y mesa-vulkan-drivers libvulkan1 vulkan-tools'
    }
    else { Write-Ok 'Vulkan loader present' }
}

# Adds the current user to the groups that own the render node. This needs root,
# and Linux reads supplementary groups at login, so it cannot take effect in the
# session that runs it - hence the exit with instructions rather than a retry.
function Add-GpuGroupMembership {
    Write-Step 'Adding the current user to render and video'
    $sudo = Find-CommandPath 'sudo'
    if (-not $sudo) {
        Write-Bad 'sudo not found on this machine.'
        Write-Inf "Ask an administrator to run:  usermod -aG render,video $($script:CurrentUser)"
        exit 1
    }
    Write-Inf "running: sudo usermod -aG render,video $($script:CurrentUser)"
    & $sudo usermod -aG render,video $script:CurrentUser
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "usermod failed (exit $LASTEXITCODE)"
        exit 1
    }
    Write-Ok "$($script:CurrentUser) added to render and video"
    Write-Host ''
    Write-Inf 'Group membership is only applied at login, so THIS session still does not'
    Write-Inf 'have it. Log out and back in (or reboot), then re-run:'
    Write-Host '    pwsh ./local.code.server.ps1' -ForegroundColor White
    Write-Host ''
}

# =============================================================================
#  2) Engine: llama.cpp (Vulkan) and llama-swap
# =============================================================================
function Get-GitHubRelease {
    param([string]$Repo)
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -Headers @{ 'User-Agent' = $script:UserAgent } -TimeoutSec 30
    }
    catch {
        Write-Wrn "GitHub release lookup failed for ${Repo}: $($_.Exception.Message)"
        return $null
    }
}

function Expand-TarGz {
    param([string]$File, [string]$Dest, [int]$StripComponents = 0)
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    if ($StripComponents -gt 0) { & tar -xzf $File -C $Dest "--strip-components=$StripComponents" }
    else { & tar -xzf $File -C $Dest }
    if ($LASTEXITCODE -ne 0) { throw "tar failed to extract $File" }
}

function Install-Engine {
    Write-Step 'Engine (llama.cpp + llama-swap)'
    New-Item -ItemType Directory -Force -Path $Paths.Bin | Out-Null
    $tools = Read-JsonFile $Paths.ToolsFile

    # --- llama.cpp, prebuilt Vulkan build for Ubuntu x64 -------------------------
    $release = Get-GitHubRelease 'ggml-org/llama.cpp'
    $haveServer = Test-Path $Paths.ServerBin
    if ($null -eq $release) {
        if (-not $haveServer) { throw 'llama.cpp is missing and its release cannot be reached. Connect to the Internet and re-run.' }
        Write-Wrn "offline: keeping llama.cpp $($tools.llamaCpp)"
    }
    else {
        $asset = $release.assets | Where-Object { $_.name -like '*bin-ubuntu-vulkan-x64.tar.gz' } | Select-Object -First 1
        if (-not $asset) { throw "no ubuntu-vulkan-x64 asset in llama.cpp release $($release.tag_name)" }
        if ($haveServer -and $tools.llamaCpp -eq $release.tag_name) {
            Write-Ok "llama.cpp $($release.tag_name) (up to date)"
        }
        else {
            Write-Inf "installing llama.cpp $($release.tag_name)"
            $archive = Join-Path $Paths.Run $asset.name
            Invoke-ResumableDownload -Url $asset.browser_download_url -Dest $archive -ExpectedSize ([int64]$asset.size) -Label $asset.name
            if (Test-Path $Paths.Engine) { Remove-Item $Paths.Engine -Recurse -Force }
            Expand-TarGz -File $archive -Dest $Paths.Engine -StripComponents 1
            Remove-Item $archive -Force -ErrorAction SilentlyContinue
            & chmod +x $Paths.ServerBin
            $tools.llamaCpp = $release.tag_name
            Write-Ok "llama.cpp $($release.tag_name) -> $($Paths.Engine)"
        }
    }
    if (-not (Test-Path $Paths.ServerBin)) { throw "llama-server not found at $($Paths.ServerBin)" }

    # --- llama-swap --------------------------------------------------------------
    $release = Get-GitHubRelease 'mostlygeek/llama-swap'
    $haveSwap = Test-Path $Paths.SwapBin
    if ($null -eq $release) {
        if (-not $haveSwap) { throw 'llama-swap is missing and its release cannot be reached. Connect to the Internet and re-run.' }
        Write-Wrn "offline: keeping llama-swap $($tools.llamaSwap)"
    }
    else {
        $asset = $release.assets | Where-Object { $_.name -like '*linux_amd64.tar.gz' } | Select-Object -First 1
        if (-not $asset) { throw "no linux_amd64 asset in llama-swap release $($release.tag_name)" }
        if ($haveSwap -and $tools.llamaSwap -eq $release.tag_name) {
            Write-Ok "llama-swap $($release.tag_name) (up to date)"
        }
        else {
            Write-Inf "installing llama-swap $($release.tag_name)"
            $archive = Join-Path $Paths.Run $asset.name
            Invoke-ResumableDownload -Url $asset.browser_download_url -Dest $archive -ExpectedSize ([int64]$asset.size) -Label $asset.name
            Expand-TarGz -File $archive -Dest $Paths.Bin
            Remove-Item $archive -Force -ErrorAction SilentlyContinue
            & chmod +x $Paths.SwapBin
            $tools.llamaSwap = $release.tag_name
            Write-Ok "llama-swap $($release.tag_name) -> $($Paths.SwapBin)"
        }
    }
    if (-not (Test-Path $Paths.SwapBin)) { throw "llama-swap not found at $($Paths.SwapBin)" }

    Write-JsonFile -Path $Paths.ToolsFile -Value $tools
}

# Ask llama.cpp itself which devices it can see. This is the only check that
# settles the question: it exercises the real Vulkan loader, driver and node
# permissions in one go. '--list-devices' lists non-CPU devices only, printing
# '(none)' when there are none, and exits 0 either way.
function Test-GpuDevice {
    Write-Step 'GPU visible to llama.cpp'
    $command = 'LD_LIBRARY_PATH=' + (ConvertTo-ShellArgument $Paths.Engine) + ' ' +
    (ConvertTo-ShellArgument $Paths.ServerBin) + ' --list-devices 2>/dev/null'
    $output = @()
    try { $output = @(& /bin/sh -c $command) }
    catch { Write-Wrn "could not run llama-server --list-devices: $($_.Exception.Message)" }

    $devices = @()
    $inList = $false
    foreach ($line in $output) {
        $text = "$line".Trim()
        if ($text -match '^Available devices:') { $inList = $true; continue }
        if (-not $inList -or $text -eq '' -or $text -eq '(none)') { continue }
        $devices += $text
    }

    if ($devices.Count -gt 0) {
        foreach ($device in $devices) { Write-Ok $device }
        return
    }

    Write-Bad 'llama.cpp sees no GPU: every model would run on the CPU.'
    Write-Inf 'On this hardware that is roughly 2 tokens/s instead of 40-55 - the 120B'
    Write-Inf 'model would be unusable. Usual causes, in order of likelihood:'
    Write-Inf "  1. this user cannot open /dev/dri/renderD* -> sudo usermod -aG render,video $($script:CurrentUser)"
    Write-Inf '     (then log out and back in), or re-run this script with -FixGroups'
    Write-Inf '  2. no Vulkan driver -> sudo apt install -y mesa-vulkan-drivers libvulkan1'
    Write-Inf '  3. the GPU carve-out or GTT limit is wrong -> see docs/ryzen-ai-halo-review-server.md'
    if (-not $Force -and -not (Confirm-Continue '    Continue anyway, serving on CPU?')) {
        throw 'no GPU available (re-run with -Force to serve on CPU regardless)'
    }
    Write-Wrn 'continuing with CPU-only inference'
}

# =============================================================================
#  3) Weights
# =============================================================================
# Hugging Face answers the first (unredirected) response with the true size in
# X-Linked-Size and the content hash in X-Linked-ETag. Following the redirect would
# replace both with CDN values, so redirects are deliberately not followed.
#
# HttpClient rather than Invoke-WebRequest: with -MaximumRedirection 0 the cmdlet
# still emits a "maximum redirection count exceeded" error that -SkipHttpErrorCheck
# does not suppress, and under $ErrorActionPreference = 'Stop' that turns every
# probe into a failure - which would silently make all models look unreachable.
function Get-RemoteFileInfo {
    param([string]$Url)
    $handler = $null
    $client = $null
    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(45)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Url)
        $request.Headers.UserAgent.ParseAdd($script:UserAgent)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ge 400) {
            Write-Debug "HEAD $Url returned $status"
            return $null
        }
        $size = Get-HttpHeaderValue $response.Headers 'X-Linked-Size'
        if (-not $size -and $status -eq 200) { $size = $response.Content.Headers.ContentLength }
        $tag = Get-HttpHeaderValue $response.Headers 'X-Linked-ETag'
        if (-not $tag) { $tag = Get-HttpHeaderValue $response.Headers 'ETag' }
        if (-not $size) { return $null }
        return [pscustomobject]@{ Size = [int64]$size; Tag = ("$tag").Trim('"') }
    }
    catch {
        Write-Debug "HEAD failed for ${Url}: $_"
        return $null
    }
    finally {
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

function Invoke-DotNetDownload {
    param([string]$Url, [string]$Part, [int64]$ExpectedSize)
    $offset = 0L
    if (Test-Path $Part) { $offset = (Get-Item $Part).Length }
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromHours(12)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        $request.Headers.UserAgent.ParseAdd($script:UserAgent)
        if ($offset -gt 0) { $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($offset, $null) }
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode) from $Url" }
        if ($offset -gt 0 -and [int]$response.StatusCode -ne 206) {
            $offset = 0L                          # server ignored the range: start over
            Remove-Item $Part -Force -ErrorAction SilentlyContinue
        }
        $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $mode = if ($offset -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $target = [System.IO.FileStream]::new($Part, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $buffer = [byte[]]::new(1MB)
            $done = $offset
            $nextReport = 0
            while ($true) {
                $read = $source.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $target.Write($buffer, 0, $read)
                $done += $read
                if ($ExpectedSize -gt 0) {
                    $percent = [int](100 * $done / $ExpectedSize)
                    if ($percent -ge $nextReport) {
                        Write-Inf "  $percent% ($(Format-Size $done) of $(Format-Size $ExpectedSize))"
                        $nextReport = $percent + 10
                    }
                }
            }
        }
        finally { $target.Dispose(); $source.Dispose() }
    }
    finally { $client.Dispose() }
}

function Invoke-ResumableDownload {
    param([string]$Url, [string]$Dest, [int64]$ExpectedSize, [string]$Label)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
    $part = "$Dest.part"
    # A partial file larger than the target can only be leftover garbage: resuming
    # from beyond the end would fail, so start it again.
    if ($ExpectedSize -gt 0 -and (Test-Path $part) -and (Get-Item $part).Length -gt $ExpectedSize) {
        Remove-Item $part -Force
    }
    $curl = Find-CommandPath 'curl'
    if ($curl) {
        $curlArgs = @('-L', '--fail', '--retry', '5', '--retry-delay', '5', '--retry-connrefused',
            '--progress-bar', '-H', "User-Agent: $($script:UserAgent)")
        if (Test-Path $part) { $curlArgs += @('-C', '-') }   # only resume when there is something to resume
        $curlArgs += @('-o', $part, $Url)
        & $curl @curlArgs
        if ($LASTEXITCODE -ne 0) { throw "curl exited $LASTEXITCODE while fetching $Label" }
    }
    else {
        Invoke-DotNetDownload -Url $Url -Part $part -ExpectedSize $ExpectedSize
    }
    if (-not (Test-Path $part)) { throw "download produced no file for $Label" }
    $actual = (Get-Item $part).Length
    if ($ExpectedSize -gt 0 -and $actual -ne $ExpectedSize) {
        throw "$Label is $actual bytes, expected $ExpectedSize - the partial file was kept for the next attempt"
    }
    Move-Item -Path $part -Destination $Dest -Force
}

# Decide, for every catalog file, whether it is current, resumable, missing or
# unreachable. Runs before anything is downloaded so the disk check sees the truth.
function Get-ModelPlan {
    $manifest = Read-JsonFile $Paths.Manifest
    if (-not $manifest.ContainsKey('files')) { $manifest['files'] = @{} }
    $plan = @()
    foreach ($model in $script:Catalog) {
        foreach ($remotePath in $model.Files) {
            $fileName = Split-Path -Leaf $remotePath
            $key = "$($model.Dir)/$fileName"
            $local = Join-Path (Join-Path $Paths.Models $model.Dir) $fileName
            $url = "https://huggingface.co/$($model.Repo)/resolve/main/$remotePath"
            $localSize = 0L
            if (Test-Path $local) { $localSize = (Get-Item $local).Length }
            $partSize = 0L
            if (Test-Path "$local.part") { $partSize = (Get-Item "$local.part").Length }
            $recorded = $null
            if ($manifest['files'].ContainsKey($key)) { $recorded = $manifest['files'][$key] }

            $remote = $null
            if (-not $NoDownload) { $remote = Get-RemoteFileInfo $url }

            $state = 'download'
            $needBytes = 0L
            if ($null -eq $remote) {
                if ($localSize -gt 0) { $state = 'offline-keep' }
                else { $state = 'offline-missing' }
            }
            elseif ($localSize -eq $remote.Size -and ($null -eq $recorded -or $recorded.tag -eq $remote.Tag)) {
                $state = 'current'
            }
            elseif ($localSize -gt 0 -and $localSize -ne $remote.Size) {
                $state = 'download'                       # replaced upstream, or truncated
                $needBytes = $remote.Size
            }
            else {
                $state = 'download'
                $needBytes = [math]::Max(0L, $remote.Size - $partSize)
            }

            $plan += [pscustomobject]@{
                ModelId    = $model.Id
                Key        = $key
                Url        = $url
                Local      = $local
                RemoteSize = if ($remote) { $remote.Size } else { 0L }
                RemoteTag  = if ($remote) { $remote.Tag } else { '' }
                LocalSize  = $localSize
                State      = $state
                NeedBytes  = $needBytes
            }
        }
    }
    return $plan
}

function Sync-Model {
    Write-Step 'Models'
    New-Item -ItemType Directory -Force -Path $Paths.Models | Out-Null

    if ($NoDownload) { Write-Inf '-NoDownload: serving the weights already on disk' }
    $plan = Get-ModelPlan

    $toFetch = @($plan | Where-Object { $_.State -eq 'download' })
    $needBytes = ($toFetch | Measure-Object -Property NeedBytes -Sum).Sum
    if ($null -eq $needBytes) { $needBytes = 0L }

    if ($toFetch.Count -gt 0) {
        Write-Inf "$($toFetch.Count) file(s) to download, about $(Format-Size $needBytes)"
        $freeGB = Get-FreeDiskGB $Paths.Models
        $neededGB = [math]::Round(($needBytes / 1GB) + 5, 1)   # 5 GiB of headroom
        if ($freeGB -ge 0 -and $freeGB -lt $neededGB) {
            Write-Bad "free space on $($Paths.Models): $freeGB GB, need about $neededGB GB"
            if (-not $Force -and -not (Confirm-Continue 'Continue anyway?')) {
                throw 'not enough free disk space (re-run with -Force to override)'
            }
        }
        else { Write-Ok "free space: $freeGB GB" }
    }

    $manifest = Read-JsonFile $Paths.Manifest
    if (-not $manifest.ContainsKey('files')) { $manifest['files'] = @{} }

    foreach ($item in $plan) {
        switch ($item.State) {
            'current' { Write-Ok "$($item.Key) (up to date, $(Format-Size $item.LocalSize))" }
            'offline-keep' {
                if ($NoDownload) { Write-Ok "$($item.Key) (local copy, $(Format-Size $item.LocalSize))" }
                else { Write-Wrn "$($item.Key): upstream unreachable, using the local copy ($(Format-Size $item.LocalSize))" }
            }
            'offline-missing' {
                if ($NoDownload) { Write-Bad "$($item.Key): not downloaded yet, and -NoDownload was given" }
                else { Write-Bad "$($item.Key): upstream unreachable and no local copy" }
            }
            'download' {
                if ($item.LocalSize -gt 0 -and $item.LocalSize -ne $item.RemoteSize) {
                    Write-Inf "$($item.Key): upstream changed, replacing"
                    Remove-Item $item.Local -Force
                }
                Write-Inf "downloading $($item.Key) ($(Format-Size $item.RemoteSize))"
                try {
                    Invoke-ResumableDownload -Url $item.Url -Dest $item.Local -ExpectedSize $item.RemoteSize -Label $item.Key
                    $manifest['files'][$item.Key] = @{
                        size    = $item.RemoteSize
                        tag     = $item.RemoteTag
                        url     = $item.Url
                        updated = (Get-Date -Format 'o')
                    }
                    Write-JsonFile -Path $Paths.Manifest -Value $manifest
                    Write-Ok "$($item.Key)"
                }
                catch {
                    Write-Bad "$($item.Key): $($_.Exception.Message)"
                    if ((Test-Path $item.Local)) { Write-Wrn 'an older local copy is present and will be served' }
                }
            }
        }
    }

    # A model is ready when every one of its files exists locally.
    $ready = @()
    foreach ($model in $script:Catalog) {
        $missing = @($model.Files | Where-Object {
                -not (Test-Path (Join-Path (Join-Path $Paths.Models $model.Dir) (Split-Path -Leaf $_)))
            })
        if ($missing.Count -eq 0) { $ready += $model.Id }
        else { Write-Wrn "$($model.Id) is incomplete and will not be served" }
    }
    if ($ready.Count -eq 0) { throw 'no model is available to serve' }
    return $ready
}

# =============================================================================
#  4) llama-swap configuration
# =============================================================================
function Get-LlamaSwapConfigText {
    param([string[]]$ReadyIds)

    $builder = [System.Text.StringBuilder]::new()
    $add = { param([string]$Line) $null = $builder.AppendLine($Line) }

    & $add '# Generated by local.code.server.ps1 - regenerated on every run, do not edit.'
    & $add '# Model roles, contexts and groups follow docs/ryzen-ai-halo-review-server.md.'
    & $add 'healthCheckTimeout: 900        # 70 GB off a cold page cache is slow'
    & $add 'logLevel: info'
    & $add 'startPort: 10001'
    & $add 'sendLoadingState: true         # Continue shows "loading" instead of stalling'
    & $add ''
    & $add 'macros:'
    & $add ('  bin: "' + $Paths.ServerBin + '"')
    & $add '  common: >-'
    & $add '    --host 127.0.0.1 --port ${PORT}'
    & $add '    -ngl 999 --no-mmap -fa on'
    & $add '    --cache-type-k q8_0 --cache-type-v q8_0'
    & $add '    --metrics --jinja'
    & $add ''
    & $add 'models:'

    foreach ($model in $script:Catalog) {
        if ($ReadyIds -notcontains $model.Id) { continue }
        # Joined with '/' rather than Join-Path: this string is a command line for a
        # Linux process, so it must not pick up a host-specific separator.
        $weights = @($Paths.Models.TrimEnd('/'), $model.Dir, (Split-Path -Leaf $model.Files[0])) -join '/'
        & $add ''
        & $add ('  ' + $model.Id + ':')
        & $add ('    name: "' + $model.Title + '"')
        & $add '    env:'
        & $add ('      - "LD_LIBRARY_PATH=' + $Paths.Engine + '"')
        & $add '    cmd: |'
        & $add ('      ' + $model.CmdHead)
        & $add ('      -m ' + $weights)
        foreach ($line in $model.CmdTail) { & $add ('      ' + $line) }
        $aliases = ($model.Aliases | ForEach-Object { '"' + $_ + '"' }) -join ', '
        & $add ('    aliases: [' + $aliases + ']')
        if ($model.Ttl -gt 0) { & $add ('    ttl: ' + $model.Ttl) }
    }

    $groupLines = @()
    foreach ($groupName in $script:GroupSpec.Keys) {
        $members = @($script:Catalog | Where-Object { $_.Group -eq $groupName -and $ReadyIds -contains $_.Id } |
                ForEach-Object { '"' + $_.Id + '"' })
        if ($members.Count -eq 0) { continue }
        $spec = $script:GroupSpec[$groupName]
        $groupLines += ('  ' + $groupName + ':')
        $groupLines += ('    swap: ' + $spec.Swap.ToString().ToLower())
        $groupLines += ('    exclusive: ' + $spec.Exclusive.ToString().ToLower())
        if ($spec.Persistent) { $groupLines += '    persistent: true' }
        $groupLines += ('    members: [' + ($members -join ', ') + ']')
    }
    if ($groupLines.Count -gt 0) {
        & $add ''
        & $add 'groups:'
        foreach ($line in $groupLines) { & $add $line }
    }

    return $builder.ToString()
}

function Save-LlamaSwapConfig {
    param([string[]]$ReadyIds)
    Write-Step 'Configuration'
    $text = Get-LlamaSwapConfigText -ReadyIds $ReadyIds
    $existing = ''
    if (Test-Path $Paths.Config) { $existing = Get-Content -Raw -Path $Paths.Config }
    if ($existing -eq $text) {
        Write-Ok "run/llama-swap.yaml unchanged ($($ReadyIds.Count) model(s))"
        return $false
    }
    [System.IO.File]::WriteAllText($Paths.Config, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "run/llama-swap.yaml written ($($ReadyIds.Count) model(s): $($ReadyIds -join ', '))"
    return $true
}

# =============================================================================
#  5) Process control
# =============================================================================
function Get-RunningServerPid {
    if (-not (Test-Path $Paths.PidFile)) { return 0 }
    $raw = (Get-Content -Raw -Path $Paths.PidFile).Trim()
    if ($raw -notmatch '^\d+$') { return 0 }
    $processId = [int]$raw
    $cmdlineFile = "/proc/$processId/cmdline"
    if (-not (Test-Path $cmdlineFile)) { return 0 }
    try { $cmdline = [System.IO.File]::ReadAllText($cmdlineFile) }
    catch { return 0 }
    if ($cmdline -notlike '*llama-swap*') { return 0 }
    return $processId
}

function Stop-ServerProcess {
    $processId = Get-RunningServerPid
    if ($processId -eq 0) {
        Write-Inf 'no server is running'
        Remove-Item $Paths.PidFile -Force -ErrorAction SilentlyContinue
        return
    }
    # SIGTERM, so llama-swap unloads its llama-server children and frees the GPU.
    Write-Inf "stopping llama-swap (pid $processId)"
    & /bin/sh -c "kill -TERM $processId" 2>$null | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if ((Get-RunningServerPid) -eq 0) { break }
    }
    if ((Get-RunningServerPid) -ne 0) {
        Write-Wrn 'still running after 30 s, sending SIGKILL'
        & /bin/sh -c "kill -KILL $processId" 2>$null | Out-Null
        Start-Sleep -Seconds 2
    }
    Remove-Item $Paths.PidFile -Force -ErrorAction SilentlyContinue
    Write-Ok 'server stopped'
}

function Wait-ServerReady {
    param([int]$TimeoutSeconds = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5
            if ($response) { return $true }
        }
        catch { Start-Sleep -Seconds 2 }
        if ((Get-RunningServerPid) -eq 0) { return $false }
    }
    return $false
}

function Start-ServerProcess {
    $listen = "${BindAddress}:${Port}"
    $command = 'nohup ' + (ConvertTo-ShellArgument $Paths.SwapBin) +
    ' --config ' + (ConvertTo-ShellArgument $Paths.Config) +
    ' --listen ' + (ConvertTo-ShellArgument $listen) +
    ' >> ' + (ConvertTo-ShellArgument $Paths.Log) + ' 2>&1 & echo $!'
    $output = & /bin/sh -c $command
    $processId = ("$output").Trim()
    if ($processId -notmatch '^\d+$') { throw "could not start llama-swap (unexpected output: '$output')" }
    Set-Content -Path $Paths.PidFile -Value $processId -NoNewline
    Write-Inf "llama-swap started (pid $processId), waiting for the API"
    if (-not (Wait-ServerReady)) {
        Write-Bad "the API did not answer on port $Port"
        Write-Inf "last lines of $($Paths.Log):"
        Get-Content -Path $Paths.Log -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Inf "  $_" }
        throw 'llama-swap did not become ready'
    }
    Write-Ok "listening on $listen"
}

function Get-LanAddress {
    try {
        $lines = & ip -4 -o addr show scope global 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $lines) {
                if ($line -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') {
                    if ($Matches[1] -ne '127.0.0.1') { return $Matches[1] }
                }
            }
        }
    }
    catch { Write-Debug "ip addr failed: $_" }
    try {
        foreach ($address in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) {
            if ($address.AddressFamily -eq 'InterNetwork' -and $address.ToString() -ne '127.0.0.1') {
                return $address.ToString()
            }
        }
    }
    catch { Write-Debug "DNS lookup failed: $_" }
    return '127.0.0.1'
}

function Show-ServerStatus {
    Write-Step 'Server status'
    $processId = Get-RunningServerPid
    if ($processId -eq 0) {
        Write-Inf 'not running'
        Write-Inf "start it with:  pwsh ./local.code.server.ps1"
        return
    }
    Write-Ok "running (pid $processId)"
    Write-Inf "config: $($Paths.Config)"
    Write-Inf "log:    $($Paths.Log)"
    try {
        $models = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 10
        $ids = @($models.data | ForEach-Object { $_.id })
        Write-Ok "API answering on port ${Port}: $($ids -join ', ')"
        Write-Inf "URL for local.code.client.ps1:  http://$(Get-LanAddress):$Port"
    }
    catch {
        Write-Wrn "the process is up but port $Port does not answer: $($_.Exception.Message)"
    }
}

# =============================================================================
#  Main
# =============================================================================
New-Item -ItemType Directory -Force -Path $Paths.Run | Out-Null

if ($Status) { Show-ServerStatus; exit 0 }
if ($Stop) { Write-Step 'Stopping'; Stop-ServerProcess; exit 0 }
if ($FixGroups) { Add-GpuGroupMembership; exit 0 }

Write-Host ''
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '|  Local Code AI - server (llama.cpp + llama-swap, OpenAI /v1)   |' -ForegroundColor Cyan
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Cyan
Write-Inf "root:   $($Paths.Root)"
Write-Inf "models: $($Paths.Models)"

Test-Prerequisite
Install-Engine
Test-GpuDevice          # before the download: 145 GiB is a lot to fetch for a CPU
$readyIds = Sync-Model
$configChanged = Save-LlamaSwapConfig -ReadyIds $readyIds

Write-Step 'Serving'
$running = Get-RunningServerPid
if ($Restart -and $running -ne 0) {
    Stop-ServerProcess
    $running = 0
}
elseif ($running -ne 0 -and $configChanged) {
    Write-Inf 'configuration changed, restarting the server'
    Stop-ServerProcess
    $running = 0
}

if ($running -ne 0) {
    Write-Ok "already running (pid $running), left untouched"
    if (-not (Wait-ServerReady -TimeoutSeconds 15)) {
        Write-Wrn 'the running process does not answer; restarting it'
        Stop-ServerProcess
        Start-ServerProcess
    }
}
else {
    Start-ServerProcess
}

$address = Get-LanAddress
$baseUrl = "http://${address}:${Port}"

Write-Host ''
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Green
Write-Host '|  Server ready                                                 |' -ForegroundColor Green
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Green
Write-Inf "OpenAI base URL : $baseUrl/v1"
Write-Inf "llama-swap UI   : $baseUrl/"
Write-Inf "models          : $($readyIds -join ', ')"
Write-Inf "log             : $($Paths.Log)"
Write-Host ''
Write-Inf 'Configure a workstation with:'
Write-Host "    pwsh ./local.code.client.ps1 -ServerUrl $baseUrl" -ForegroundColor White
Write-Host ''
Write-Inf 'Manage this server with:  -Status | -Stop | -Restart'
Write-Host ''
