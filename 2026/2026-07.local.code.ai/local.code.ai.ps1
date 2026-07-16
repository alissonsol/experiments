<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42c0de0a-1b2c-4d3e-8f45-a1b2c3d4e5f6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Local Code AI - one-shot setup for a local, GPU-backed code refactoring stack.

.DESCRIPTION
    Sets up everything needed to refactor & format Go, PowerShell, Rust and JavaScript
    locally with an Ollama-served model plus deterministic formatters, and installs a
    VS Code extension ("Local Code AI") that drives it for the currently open project
    and adds a project-aware chat (as an editor tab or in the side bar) for free-form
    conversations with the local model about the code that is actually open.

    What it does, in order:
      1. Prerequisite checks .... RAM, GPU (nvidia-smi on Windows/Linux; unified
                                  memory on macOS) and free disk space. A GPU is
                                  OPTIONAL: with none found the script confirms
                                  CPU-only inference (slow) and picks a small model.
      2. Ollama ................. installs it if missing (winget or direct download on
                                  Windows; Homebrew or a portable GitHub build on
                                  macOS; official script or a portable GitHub build
                                  on Linux) and points OLLAMA_MODELS at <Root>/models
                                  so the model weights live inside one folder.
      3. Model .................. pulls a coder model sized to the available VRAM or
                                  unified memory (e.g. 24 GB -> qwen3-coder:30b) and
                                  creates the alias 'localcoder' with an enlarged
                                  context window.
      4. Tools .................. uses installed toolchains when found, otherwise
                                  downloads portable copies into <Root>\tools:
                                  gofumpt (Go), rustfmt (Rust), Node.js + prettier
                                  (JavaScript), PSScriptAnalyzer (PowerShell).
                                  Tool locations are recorded in <Root>\tools\paths.json.
      5. VS Code extension ...... copies the extension source (project-aware chat +
                                  refactor commands) from .\extension\local-code-ai
                                  next to this script into <Root>\extension\local-code-ai,
                                  packages it with vsce and installs the .vsix into VS Code.

    Behavior of the extension: edits are AUTO-APPLIED and SAVED (never committed).
    A confirmation warning appears when a workspace run would touch more than 50
    files - change via the 'localCodeAI.maxFilesBeforeWarning' setting.

    Runs on Windows, macOS and Ubuntu (PowerShell 7+ required; VS Code for the
    extension). No administrator rights are needed for the portable fallbacks.

.PARAMETER Root
    Installation folder. Default: C:\LocalCodeAI (Windows) or ~/LocalCodeAI (macOS/Linux).

.PARAMETER ModelTag
    Override automatic model selection (e.g. 'qwen2.5-coder:14b').

.PARAMETER ContextTokens
    Override the context window baked into the 'localcoder' alias.

.PARAMETER ModelAlias
    Name of the Ollama alias the extension talks to. Default: localcoder.

.PARAMETER SkipModel
    Skip the model pull/alias phase (useful for re-runs).

.PARAMETER SkipTools
    Skip the formatter-toolchain phase (useful for re-runs).

.PARAMETER SkipExtension
    Skip the VS Code extension build/install phase (useful for re-runs).

.PARAMETER KeepExistingOllamaModelPath
    Do not redirect OLLAMA_MODELS into <Root>\models (keeps Ollama's default store).

.PARAMETER Yes
    Non-interactive: auto-accept all confirmation prompts.

.PARAMETER Force
    Proceed even if the free-disk check fails; re-pull model even if present.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\local.code.ai.ps1

.EXAMPLE
    pwsh ./local.code.ai.ps1 -Root ~/LocalCodeAI -Yes

.NOTES
    Requires PowerShell 7+ (pwsh). On Windows: winget install Microsoft.PowerShell
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$ModelTag = '',
    [int]$ContextTokens = 0,
    [string]$ModelAlias = 'localcoder',
    [switch]$SkipModel,
    [switch]$SkipTools,
    [switch]$SkipExtension,
    [switch]$KeepExistingOllamaModelPath,
    [switch]$Yes,
    [switch]$Force
)

# --- PowerShell 7 gate (this file stays parseable by 5.1 so the message shows) ---
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'This script requires PowerShell 7+ (pwsh) for cross-platform support.' -ForegroundColor Red
    Write-Host 'Install it, then re-run:' -ForegroundColor Yellow
    Write-Host '    winget install Microsoft.PowerShell'
    Write-Host '    pwsh -ExecutionPolicy Bypass -File .\local.code.ai.ps1'
    exit 1
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest dramatically faster

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

# =============================================================================
#  Platform detection
# =============================================================================
function Get-OSKey {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}
function Get-ArchKey {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()
    if ($architecture -eq 'arm64') { return 'arm64' }
    return 'x64'
}
$script:OS = Get-OSKey
$script:Arch = Get-ArchKey
$script:Exe = ''
if ($script:OS -eq 'windows') { $script:Exe = '.exe' }

if ([string]::IsNullOrWhiteSpace($Root)) {
    if ($script:OS -eq 'windows') { $Root = 'C:\LocalCodeAI' }
    else { $Root = Join-Path $HOME 'LocalCodeAI' }
}
$Root = [System.IO.Path]::GetFullPath($Root)

$Dirs = @{
    Root      = $Root
    Models    = Join-Path $Root 'models'
    Tools     = Join-Path $Root 'tools'
    ToolsBin  = Join-Path $Root 'tools\bin'
    Downloads = Join-Path $Root 'downloads'
    Extension = Join-Path $Root 'extension'
    ExtSrc    = Join-Path $Root 'extension\local-code-ai'
    PsModules = Join-Path $Root 'tools\ps-modules'
    Prettier  = Join-Path $Root 'tools\prettier'
    NodeDir   = Join-Path $Root 'tools\node'
}
if ($script:OS -ne 'windows') {
    # Rebuild with forward-slash joins for non-Windows.
    $Dirs.ToolsBin = Join-Path $Dirs.Tools 'bin'
    $Dirs.ExtSrc = Join-Path $Dirs.Extension 'local-code-ai'
    $Dirs.PsModules = Join-Path $Dirs.Tools 'ps-modules'
    $Dirs.Prettier = Join-Path $Dirs.Tools 'prettier'
    $Dirs.NodeDir = Join-Path $Dirs.Tools 'node'
}

# =============================================================================
#  Download / archive helpers
# =============================================================================
function Invoke-Download {
    param([string]$Url, [string]$Dest)
    $tries = 0
    while ($true) {
        $tries++
        try {
            Write-Inf "downloading $Url"
            Invoke-WebRequest -Uri $Url -OutFile $Dest -Headers @{ 'User-Agent' = 'LocalCodeAI-Setup' } -MaximumRedirection 10
            return
        }
        catch {
            if ($tries -ge 3) { throw }
            Write-Wrn "download failed (attempt $tries), retrying... $($_.Exception.Message)"
            Start-Sleep -Seconds (3 * $tries)
        }
    }
}

function Expand-ArchiveAny {
    param([string]$File, [string]$Dest)
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    if ($File -like '*.zip') {
        Expand-Archive -Path $File -DestinationPath $Dest -Force
    }
    else {
        # bsdtar ships with Windows 10+, macOS and Linux; handles .tar.gz and .tar.xz
        & tar -xf $File -C $Dest
        if ($LASTEXITCODE -ne 0) { throw "tar failed to extract $File" }
    }
}

# Resolve a release asset URL. Tries the GitHub API first; if rate-limited or
# blocked, falls back to scraping the releases page (no auth required).
function Get-GitHubAssetUrl {
    param([string]$Repo, [string[]]$Patterns)
    $assets = @()
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -Headers @{ 'User-Agent' = 'LocalCodeAI-Setup' } -TimeoutSec 30
        foreach ($asset in $release.assets) { $assets += [pscustomobject]@{ Name = $asset.name; Url = $asset.browser_download_url } }
    }
    catch {
        Write-Inf "GitHub API unavailable for $Repo ($($_.Exception.Message)); using releases page"
        try {
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $client = [System.Net.Http.HttpClient]::new($handler)
            $client.DefaultRequestHeaders.UserAgent.ParseAdd('LocalCodeAI-Setup')
            $response = $client.GetAsync("https://github.com/$Repo/releases/latest").GetAwaiter().GetResult()
            $location = $response.Headers.Location
            if ($null -eq $location) { throw 'no redirect from /releases/latest' }
            $tag = ($location.ToString() -split '/tag/')[-1]
            $html = (Invoke-WebRequest -Uri "https://github.com/$Repo/releases/expanded_assets/$tag" `
                    -Headers @{ 'User-Agent' = 'LocalCodeAI-Setup' }).Content
            $rx = [regex]'href="(/' + [regex]::Escape($Repo) + '/releases/download/[^"]+)"'
            foreach ($match in $rx.Matches($html)) {
                $url = 'https://github.com' + $match.Groups[1].Value
                $assets += [pscustomobject]@{ Name = ($url -split '/')[-1]; Url = $url }
            }
        }
        catch {
            Write-Wrn "could not list release assets for ${Repo}: $($_.Exception.Message)"
            return $null
        }
    }
    foreach ($pattern in $Patterns) {
        $hit = $assets | Where-Object { $_.Name -like $pattern } | Select-Object -First 1
        if ($hit) { return $hit.Url }
    }
    return $null
}

function Find-Command {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

# =============================================================================
#  1) Prerequisite checks
# =============================================================================
function Get-TotalMemoryGB {
    try {
        if ($script:OS -eq 'windows') {
            $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
            return [math]::Round($bytes / 1GB, 1)
        }
        if ($script:OS -eq 'macos') {
            $bytes = [int64](& sysctl -n hw.memsize)
            return [math]::Round($bytes / 1GB, 1)
        }
        $kb = [int64]((Get-Content /proc/meminfo | Select-String '^MemTotal:') -replace '[^\d]', '')
        return [math]::Round($kb / 1MB, 1)
    }
    catch { return 0 }
}

function Get-FreeDiskGB {
    param([string]$Path)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $drive = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $full.StartsWith($_.RootDirectory.FullName, [System.StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object { $_.RootDirectory.FullName.Length } -Descending |
            Select-Object -First 1
        if ($drive) { return [math]::Round($drive.AvailableFreeSpace / 1GB, 1) }
    }
    catch { }
    return -1
}

function Get-NvidiaInfo {
    $smi = Find-Command 'nvidia-smi'
    if (-not $smi) {
        # Default install location is not always on PATH on Windows.
        $path = "$env:SystemRoot\System32\nvidia-smi.exe"
        if ($script:OS -eq 'windows' -and (Test-Path $path)) { $smi = $path }
    }
    if (-not $smi) { return $null }
    try {
        # Arguments must stay quoted: unquoted 'a, b' is a PowerShell array and the
        # elements reach nvidia-smi as separate (invalid) arguments.
        $lines = & $smi '--query-gpu=name,memory.total' '--format=csv,noheader,nounits' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $lines) { return $null }
        $best = 0; $names = @()
        foreach ($line in @($lines)) {
            $parts = $line -split ','
            if ($parts.Count -ge 2) {
                $names += $parts[0].Trim()
                $mib = 0
                if ([int]::TryParse($parts[1].Trim(), [ref]$mib)) {
                    if ($mib -gt $best) { $best = $mib }
                }
            }
        }
        return [pscustomobject]@{ VramGB = [math]::Round($best / 1024, 1); Names = ($names -join '; ') }
    }
    catch { return $null }
}

function Select-ModelTier {
    param([double]$VramGB, [double]$UnifiedGB)
    # Tiers keyed to what actually fits at Q4 with a real context window.
    if ($VramGB -ge 20) { return [pscustomobject]@{ Tag = 'qwen3-coder:30b'; Ctx = 32768; DlGB = 19; Note = 'MoE 30B (3.3B active) - best coder for 24 GB cards' } }
    if ($VramGB -ge 11) { return [pscustomobject]@{ Tag = 'qwen2.5-coder:14b'; Ctx = 16384; DlGB = 9; Note = '14B dense coder' } }
    if ($VramGB -ge 7) { return [pscustomobject]@{ Tag = 'qwen2.5-coder:7b'; Ctx = 16384; DlGB = 5; Note = '7B dense coder' } }
    if ($UnifiedGB -ge 32) { return [pscustomobject]@{ Tag = 'qwen3-coder:30b'; Ctx = 32768; DlGB = 19; Note = 'Apple unified memory - MoE 30B' } }
    if ($UnifiedGB -ge 18) { return [pscustomobject]@{ Tag = 'qwen2.5-coder:14b'; Ctx = 16384; DlGB = 9; Note = 'Apple unified memory - 14B' } }
    return [pscustomobject]@{ Tag = 'qwen2.5-coder:7b'; Ctx = 8192; DlGB = 5; Note = 'no/low GPU detected - CPU inference will be SLOW' }
}

function Test-Prerequisites {
    Write-Step 'Checking prerequisites (memory / GPU / disk)'
    $ramGB = Get-TotalMemoryGB
    if ($ramGB -ge 32) { Write-Ok  "RAM: $ramGB GB" }
    elseif ($ramGB -ge 16) { Write-Wrn "RAM: $ramGB GB (32 GB recommended; large workspace runs may swap)" }
    else { Write-Wrn "RAM: $ramGB GB - below 16 GB things will be painful" }

    $gpu = $null; $unifiedGB = 0
    if ($script:OS -eq 'macos') {
        $unifiedGB = $ramGB
        Write-Inf "macOS: using unified memory ($unifiedGB GB) for model sizing"
    }
    else {
        $gpu = Get-NvidiaInfo
        if ($gpu) { Write-Ok "GPU: $($gpu.Names) - $($gpu.VramGB) GB VRAM" }
        else {
            Write-Wrn 'No NVIDIA GPU detected via nvidia-smi. Ollama will run on CPU (slow).'
            if (-not (Confirm-Continue 'Continue with CPU-only inference?')) { throw 'Aborted: no GPU.' }
        }
    }

    $vram = 0
    if ($gpu) { $vram = $gpu.VramGB }
    if ($ModelTag) {
        $script:Tier = [pscustomobject]@{ Tag = $ModelTag; Ctx = 32768; DlGB = 20; Note = 'user override (-ModelTag)' }
    }
    else {
        $script:Tier = Select-ModelTier -VramGB $vram -UnifiedGB $unifiedGB
    }
    if ($ContextTokens -gt 0) { $script:Tier.Ctx = $ContextTokens }
    Write-Ok "Model plan: $($script:Tier.Tag)  (context $($script:Tier.Ctx) tokens) - $($script:Tier.Note)"

    $needGB = [math]::Ceiling($script:Tier.DlGB * 1.15 + 8)   # model + tools + node + headroom
    $freeGB = Get-FreeDiskGB -Path $Root
    if ($freeGB -lt 0) { Write-Wrn "Could not determine free space for $Root - continuing" }
    elseif ($freeGB -ge $needGB) { Write-Ok "Disk: $freeGB GB free on target drive (need ~$needGB GB)" }
    else {
        Write-Bad "Disk: only $freeGB GB free on the drive hosting $Root (need ~$needGB GB)"
        if (-not $Force) { throw "Not enough disk space. Free up space, choose another -Root, or re-run with -Force." }
        Write-Wrn 'Continuing anyway because -Force was given.'
    }
}

# =============================================================================
#  2) Ollama
# =============================================================================
# Portable fallback: extract a release archive under <Root>/tools/ollama and use
# the binary directly - no Homebrew, no curl, no admin rights, no system service.
function Install-OllamaPortable {
    param([string[]]$Patterns)
    Write-Inf 'downloading a portable Ollama build from GitHub releases...'
    $url = Get-GitHubAssetUrl -Repo 'ollama/ollama' -Patterns $Patterns
    if (-not $url) { throw 'no Ollama release found for this platform - install manually from https://ollama.com/download and re-run.' }
    $archive = Join-Path $Dirs.Downloads (($url -split '/')[-1])
    Invoke-Download -Url $url -Dest $archive
    $dest = Join-Path $Dirs.Tools 'ollama'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-ArchiveAny -File $archive -Dest $dest
    $bin = Get-ChildItem -Path $dest -Recurse -File |
        Where-Object { $_.Name -eq 'ollama' } | Select-Object -First 1
    if (-not $bin) { throw "no ollama binary found inside $archive" }
    & chmod +x $bin.FullName | Out-Host
    $env:PATH = "$($bin.DirectoryName):$env:PATH"
    Persist-UnixPathEntry -Dir $bin.DirectoryName
    Write-Ok "Ollama (portable): $($bin.FullName)"
    return $bin.FullName
}

function Ensure-Ollama {
    Write-Step 'Ensuring Ollama is installed'
    $found = Find-Command 'ollama'
    if ($found) { Write-Ok "Ollama already installed: $found"; return $found }

    if ($script:OS -eq 'windows') {
        $winget = Find-Command 'winget'
        $installed = $false
        if ($winget) {
            Write-Inf 'installing via winget (Ollama.Ollama)...'
            & $winget install --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
            if ($LASTEXITCODE -eq 0) { $installed = $true } else { Write-Wrn "winget exited with $LASTEXITCODE - falling back to direct download" }
        }
        if (-not $installed) {
            $setup = Join-Path $Dirs.Downloads 'OllamaSetup.exe'
            Invoke-Download -Url 'https://ollama.com/download/OllamaSetup.exe' -Dest $setup
            Write-Inf 'running silent installer...'
            Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
        }
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
            'C:\Program Files\Ollama\ollama.exe'
        )
        foreach ($candidate in $candidates) {
            if (Test-Path $candidate) {
                $dir = Split-Path $candidate -Parent
                if ($env:PATH -notlike "*$dir*") { $env:PATH = "$dir;$env:PATH" }
                Write-Ok "Ollama installed: $candidate"
                return $candidate
            }
        }
        $found = Find-Command 'ollama'
        if ($found) { Write-Ok "Ollama installed: $found"; return $found }
        throw 'Ollama installation did not produce ollama.exe - install manually from https://ollama.com/download'
    }
    elseif ($script:OS -eq 'macos') {
        $brew = Find-Command 'brew'
        if (-not $brew) {
            # Homebrew is often installed but not on pwsh's PATH.
            foreach ($candidate in @('/opt/homebrew/bin/brew', '/usr/local/bin/brew')) {
                if (Test-Path $candidate) { $brew = $candidate; break }
            }
        }
        if ($brew) {
            Write-Inf 'installing via Homebrew...'
            # Out-Host keeps brew's chatter off this function's output stream,
            # which is the ollama path the caller returns.
            & $brew install ollama | Out-Host
            $found = Find-Command 'ollama'
            if (-not $found) {
                foreach ($candidate in @('/opt/homebrew/bin/ollama', '/usr/local/bin/ollama')) {
                    if (Test-Path $candidate) { $found = $candidate; break }
                }
            }
            if ($found) { Write-Ok "Ollama installed: $found"; return $found }
            Write-Wrn 'Homebrew did not produce an ollama binary - falling back to a portable build'
        }
        return Install-OllamaPortable -Patterns @('ollama-darwin.tgz', 'Ollama-darwin.zip')
    }
    else {
        if (Find-Command 'curl') {
            Write-Inf 'running official install script (may prompt for sudo)...'
            & bash -c 'curl -fsSL https://ollama.com/install.sh | sh' | Out-Host
            $found = Find-Command 'ollama'
            if ($found) { Write-Ok "Ollama installed: $found"; return $found }
            Write-Wrn 'install script did not complete - falling back to a portable build'
        }
        else { Write-Inf 'curl not found - using a portable build instead of the official installer' }
        $tarArch = @{ x64 = 'amd64'; arm64 = 'arm64' }[$script:Arch]
        return Install-OllamaPortable -Patterns @("ollama-linux-$tarArch.tgz", "ollama-linux-$tarArch.tar.zst")
    }
}

function Wait-OllamaApi {
    param([string]$Endpoint, [int]$Seconds = 40)
    for ($i = 0; $i -lt $Seconds; $i++) {
        try {
            $null = Invoke-RestMethod -Uri "$Endpoint/api/version" -TimeoutSec 3
            return $true
        }
        catch { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Configure-OllamaModelStore {
    param([string]$OllamaCmd)
    Write-Step 'Configuring Ollama model store + starting server'
    $endpoint = 'http://127.0.0.1:11434'

    if (-not $KeepExistingOllamaModelPath) {
        $env:OLLAMA_MODELS = $Dirs.Models
        if ($script:OS -eq 'windows') {
            [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $Dirs.Models, 'User')
            Write-Ok "OLLAMA_MODELS -> $($Dirs.Models) (persisted for your user)"
            # Restart any running instance so it picks up the new store.
            foreach ($processName in @('ollama', 'ollama app')) {
                Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 1
        }
        elseif ($script:OS -eq 'linux') {
            # The packaged ollama.service runs as its own 'ollama' user, which cannot
            # read a model store under this user's home directory. Disable it and let
            # this script run a per-user 'ollama serve' instead.
            $systemctl = Find-Command 'systemctl'
            $hasService = $false
            if ($systemctl) {
                $units = & $systemctl list-unit-files ollama.service 2>$null
                if (($units -join ' ') -match 'ollama\.service') { $hasService = $true }
            }
            if ($hasService) {
                $sudoOk = [bool](Find-Command 'sudo')
                if ($sudoOk -and $Yes) {
                    # Non-interactive run: never hang on a sudo password prompt.
                    & sudo -n true 2>$null
                    if ($LASTEXITCODE -ne 0) { $sudoOk = $false }
                }
                if ($sudoOk) {
                    & sudo systemctl disable --now ollama | Out-Host
                    if ($LASTEXITCODE -ne 0) { $sudoOk = $false }
                }
                if ($sudoOk) {
                    Write-Ok 'system ollama.service disabled - a per-user server will be used'
                    Write-Inf 'restore the system service later with: sudo systemctl enable --now ollama'
                }
                else {
                    Write-Wrn 'could not disable the system ollama.service - keeping its default model store'
                    $env:OLLAMA_MODELS = $null
                }
            }
            if ($env:OLLAMA_MODELS) {
                & pkill -x ollama 2>$null   # restart any user-level server with the new store
                Persist-UnixEnvLine -Name 'OLLAMA_MODELS' -Value $Dirs.Models
            }
        }
        else {
            # --- macOS path (prepared) ---
            & launchctl setenv OLLAMA_MODELS $Dirs.Models 2>$null | Out-Host
            Persist-UnixEnvLine -Name 'OLLAMA_MODELS' -Value $Dirs.Models
            & pkill -x Ollama 2>$null
            & pkill -x ollama 2>$null
        }
    }
    else {
        Write-Inf 'keeping Ollama''s default model location (-KeepExistingOllamaModelPath)'
    }

    if (-not (Wait-OllamaApi -Endpoint $endpoint -Seconds 3)) {
        Write-Inf 'starting ollama serve in the background...'
        if ($script:OS -eq 'windows') {
            Start-Process -FilePath $OllamaCmd -ArgumentList 'serve' -WindowStyle Hidden
        }
        else {
            # -WindowStyle is Windows-only; plain background start elsewhere.
            Start-Process -FilePath $OllamaCmd -ArgumentList 'serve'
        }
    }
    if (Wait-OllamaApi -Endpoint $endpoint -Seconds 40) { Write-Ok "Ollama API is up at $endpoint" }
    else { throw "Ollama API did not come up at $endpoint - try running 'ollama serve' manually and re-run setup." }
    return $endpoint
}

function Ensure-Model {
    param([string]$OllamaCmd)
    Write-Step "Pulling model $($script:Tier.Tag) and creating alias '$ModelAlias' (num_ctx=$($script:Tier.Ctx))"
    $have = ''
    try { $have = (& $OllamaCmd list) -join "`n" } catch { $have = '' }

    $tagBase = $script:Tier.Tag
    if ($Force -or ($have -notmatch [regex]::Escape($tagBase))) {
        Write-Inf "downloading $tagBase (~$($script:Tier.DlGB) GB - this is the long part)..."
        & $OllamaCmd pull $tagBase
        if ($LASTEXITCODE -ne 0) { throw "ollama pull $tagBase failed (exit $LASTEXITCODE)" }
    }
    else {
        Write-Ok "$tagBase already present - skipping pull (use -Force to re-pull)"
    }

    $modelFile = Join-Path $Dirs.Downloads 'Modelfile.localcoder'
    Set-Content -Path $modelFile -Value "FROM $tagBase`nPARAMETER num_ctx $($script:Tier.Ctx)" -Encoding utf8
    & $OllamaCmd create $ModelAlias -f $modelFile
    if ($LASTEXITCODE -ne 0) { throw "ollama create $ModelAlias failed (exit $LASTEXITCODE)" }
    Write-Ok "alias '$ModelAlias' -> $tagBase with a $($script:Tier.Ctx)-token context"
}

# =============================================================================
#  3) Formatter toolchain (use installed, fetch missing)
# =============================================================================
function Ensure-Gofumpt {
    $existing = Find-Command 'gofumpt'
    if ($existing) { Write-Ok "gofumpt (system): $existing"; return $existing }
    $dest = Join-Path $Dirs.ToolsBin "gofumpt$($script:Exe)"
    if (Test-Path $dest) { Write-Ok "gofumpt (cached): $dest"; return $dest }

    $osTag = @{ windows = 'windows'; macos = 'darwin'; linux = 'linux' }[$script:OS]
    $goArch = @{ x64 = 'amd64'; arm64 = 'arm64' }[$script:Arch]
    $url = Get-GitHubAssetUrl -Repo 'mvdan/gofumpt' -Patterns @("gofumpt_*_${osTag}_${goArch}$($script:Exe)")
    if (-not $url) {
        Write-Wrn "no gofumpt build for $osTag/$goArch - will fall back to 'gofmt' from an installed Go toolchain"
        return $null
    }
    Invoke-Download -Url $url -Dest $dest
    if ($script:OS -ne 'windows') { & chmod +x $dest }
    Write-Ok "gofumpt (downloaded): $dest"
    return $dest
}

function Ensure-Rustfmt {
    $existing = Find-Command 'rustfmt'
    if ($existing) { Write-Ok "rustfmt (system): $existing"; return $existing }
    $dest = Join-Path $Dirs.ToolsBin "rustfmt$($script:Exe)"
    if (Test-Path $dest) { Write-Ok "rustfmt (cached): $dest"; return $dest }

    $patterns = @()
    if ($script:OS -eq 'windows') { $patterns = @('*windows-x86_64-msvc*.zip', '*windows-x86_64-gnu*.zip') }
    elseif ($script:OS -eq 'macos') {
        # x86_64 last: it still runs on Apple Silicon via Rosetta.
        if ($script:Arch -eq 'arm64') { $patterns = @('*macos-aarch64*.tar.gz', '*macos-arm64*.tar.gz', '*macos-x86_64*.tar.gz') }
        else { $patterns = @('*macos-x86_64*.tar.gz') }
    }
    else {
        if ($script:Arch -eq 'arm64') { $patterns = @('*linux-aarch64*.tar.gz', '*linux-arm64*.tar.gz') }
        else { $patterns = @('*linux-x86_64*.tar.gz') }
    }
    $url = Get-GitHubAssetUrl -Repo 'rust-lang/rustfmt' -Patterns $patterns
    if (-not $url) {
        Write-Wrn 'no standalone rustfmt release found for this platform - Rust files will be skipped by the formatter unless rustup provides rustfmt'
        return $null
    }
    $archive = Join-Path $Dirs.Downloads ($url -split '/')[-1]
    Invoke-Download -Url $url -Dest $archive
    $tmp = Join-Path $Dirs.Downloads 'rustfmt-extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-ArchiveAny -File $archive -Dest $tmp
    $bin = Get-ChildItem -Path $tmp -Recurse -File |
        Where-Object { $_.Name -eq "rustfmt$($script:Exe)" } | Select-Object -First 1
    if (-not $bin) { Write-Wrn 'rustfmt binary not found inside the archive'; return $null }
    Copy-Item $bin.FullName $dest -Force
    if ($script:OS -ne 'windows') { & chmod +x $dest }
    Write-Ok "rustfmt (downloaded): $dest"
    return $dest
}

function Ensure-NodePortable {
    $node = Find-Command 'node'
    $npm = Find-Command 'npm'
    $npx = Find-Command 'npx'
    if ($node -and $npm -and $npx) {
        if ($script:OS -eq 'windows') {
            # Get-Command resolves npm/npx to their .ps1 shims, which rebuild the
            # command line from the caller's source text and mangle arguments when
            # invoked via '& $var ...' from a script. Use the .cmd shims instead.
            if ($npm -like '*.ps1') { $alt = [IO.Path]::ChangeExtension($npm, 'cmd'); if (Test-Path $alt) { $npm = $alt } }
            if ($npx -like '*.ps1') { $alt = [IO.Path]::ChangeExtension($npx, 'cmd'); if (Test-Path $alt) { $npx = $alt } }
        }
        Write-Ok "Node.js (system): $node ($(& $node --version))"
        return [pscustomobject]@{ Node = $node; Npm = $npm; Npx = $npx }
    }
    # Cached portable copy from a previous run?
    $cached = Get-ChildItem -Path $Dirs.NodeDir -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cached) {
        Write-Inf 'Node.js not found - fetching a portable LTS build (needed for prettier and vsce)...'
        $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -Headers @{ 'User-Agent' = 'LocalCodeAI-Setup' }
        $lts = $index | Where-Object { $_.lts } | Select-Object -First 1
        if (-not $lts) { throw 'could not resolve latest Node.js LTS from nodejs.org' }
        $version = $lts.version
        $file = ''
        if ($script:OS -eq 'windows') { $file = "node-$version-win-$($script:Arch).zip" }
        elseif ($script:OS -eq 'macos') { $file = "node-$version-darwin-$($script:Arch).tar.gz" }
        else { $file = "node-$version-linux-$($script:Arch).tar.xz" }
        $archive = Join-Path $Dirs.Downloads $file
        Invoke-Download -Url "https://nodejs.org/dist/$version/$file" -Dest $archive
        Expand-ArchiveAny -File $archive -Dest $Dirs.NodeDir
        $cached = Get-ChildItem -Path $Dirs.NodeDir -Directory -Filter 'node-v*' | Select-Object -First 1
        if (-not $cached) { throw 'portable Node.js extraction failed' }
    }
    $home2 = $cached.FullName
    if ($script:OS -eq 'windows') {
        $node = Join-Path $home2 'node.exe'; $npm = Join-Path $home2 'npm.cmd'; $npx = Join-Path $home2 'npx.cmd'
        $env:PATH = "$home2;$env:PATH"
    }
    else {
        $node = Join-Path $home2 'bin/node'; $npm = Join-Path $home2 'bin/npm'; $npx = Join-Path $home2 'bin/npx'
        $env:PATH = "$(Join-Path $home2 'bin'):$env:PATH"
    }
    Write-Ok "Node.js (portable): $node ($(& $node --version))"
    return [pscustomobject]@{ Node = $node; Npm = $npm; Npx = $npx }
}

function Ensure-Prettier {
    param($NodeInfo)
    $cli = Join-Path $Dirs.Prettier 'node_modules\prettier\bin\prettier.cjs'
    if ($script:OS -ne 'windows') { $cli = Join-Path $Dirs.Prettier 'node_modules/prettier/bin/prettier.cjs' }
    if (Test-Path $cli) { Write-Ok "prettier (cached): $cli"; return $cli }
    Write-Inf 'installing prettier locally (npm)...'
    New-Item -ItemType Directory -Force -Path $Dirs.Prettier | Out-Null
    & $NodeInfo.Npm install prettier --prefix $Dirs.Prettier --no-audit --no-fund --loglevel=error
    if ($LASTEXITCODE -ne 0) { Write-Wrn "npm install prettier failed (exit $LASTEXITCODE)"; return $null }
    if (Test-Path $cli) { Write-Ok "prettier: $cli"; return $cli }
    Write-Wrn 'prettier CLI not found after install'
    return $null
}

function Ensure-PSScriptAnalyzer {
    $available = Get-Module -Name PSScriptAnalyzer -ListAvailable -ErrorAction SilentlyContinue
    if ($available) {
        Write-Ok "PSScriptAnalyzer (system): v$(($available | Select-Object -First 1).Version)"
        return $null   # null path = use system module resolution
    }
    $marker = Join-Path $Dirs.PsModules 'PSScriptAnalyzer'
    if (Test-Path $marker) { Write-Ok "PSScriptAnalyzer (cached): $($Dirs.PsModules)"; return $Dirs.PsModules }
    Write-Inf 'saving PSScriptAnalyzer module locally (PSGallery)...'
    New-Item -ItemType Directory -Force -Path $Dirs.PsModules | Out-Null
    try {
        Save-Module -Name PSScriptAnalyzer -Path $Dirs.PsModules -Repository PSGallery -Force -ErrorAction Stop
        Write-Ok "PSScriptAnalyzer -> $($Dirs.PsModules)"
        return $Dirs.PsModules
    }
    catch {
        Write-Wrn "Save-Module failed: $($_.Exception.Message)"
        Write-Wrn "Try: Set-PSRepository -Name PSGallery -InstallationPolicy Trusted  (then re-run)"
        return $null
    }
}

function Ensure-Tools {
    Write-Step 'Ensuring formatter toolchain (use installed, fetch missing)'
    $manifest = [ordered]@{}
    $manifest.generatedBy = 'local.code.ai.ps1'
    $manifest.generatedAt = (Get-Date -Format 'o')
    $manifest.pwsh = (Get-Command pwsh).Source

    try { $manifest.gofumpt = Ensure-Gofumpt } catch { Write-Wrn "gofumpt: $($_.Exception.Message)"; $manifest.gofumpt = $null }
    try { $manifest.rustfmt = Ensure-Rustfmt } catch { Write-Wrn "rustfmt: $($_.Exception.Message)"; $manifest.rustfmt = $null }

    $script:NodeInfo = $null
    try { $script:NodeInfo = Ensure-NodePortable } catch { Write-Wrn "node: $($_.Exception.Message)" }
    if ($script:NodeInfo) {
        $manifest.node = $script:NodeInfo.Node
        try { $manifest.prettierCli = Ensure-Prettier -NodeInfo $script:NodeInfo } catch { Write-Wrn "prettier: $($_.Exception.Message)"; $manifest.prettierCli = $null }
    }
    else {
        $manifest.node = $null; $manifest.prettierCli = $null
    }

    try { $manifest.psModulesPath = Ensure-PSScriptAnalyzer } catch { Write-Wrn "PSScriptAnalyzer: $($_.Exception.Message)"; $manifest.psModulesPath = $null }

    $manifestPath = Join-Path $Dirs.Tools 'paths.json'
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding utf8
    Write-Ok "tool manifest written: $manifestPath"
}

# =============================================================================
#  4) VS Code extension
#     Source lives in .\extension\local-code-ai next to this script (package.json,
#     extension.js, chat.js, workspace.js, media\, README.md, LICENSE) - edit it there.
# =============================================================================
function Copy-ExtensionSource {
    Write-Step 'Copying extension source'
    $sourceDir = Join-Path $PSScriptRoot 'extension' 'local-code-ai'
    if (-not (Test-Path (Join-Path $sourceDir 'package.json'))) {
        throw "Extension source not found at $sourceDir - it ships alongside this script; restore the 'extension' folder and re-run."
    }
    New-Item -ItemType Directory -Force -Path $Dirs.ExtSrc | Out-Null
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $Dirs.ExtSrc -Recurse -Force
    Write-Ok "extension source $sourceDir -> $($Dirs.ExtSrc)"
}

function Find-VSCodeCli {
    $code = Find-Command 'code'
    if ($code) { return $code }

    $commonPaths = @(
        '/usr/bin/code',
        '/usr/local/bin/code',
        '/snap/bin/code',
        '/usr/share/code/bin/code',
        '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code',
        (Join-Path $HOME 'Applications/Visual Studio Code.app/Contents/Resources/app/bin/code'),
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
    )
    foreach ($path in $commonPaths) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Build-And-InstallExtension {
    Write-Step 'Building and installing extension'
    if (-not $script:NodeInfo) { $script:NodeInfo = Ensure-NodePortable }   # -SkipTools runs land here
    $vsixPath = Join-Path $Dirs.Extension 'local-code-ai.vsix'
    if (Test-Path $vsixPath) { Remove-Item $vsixPath }

    Push-Location $Dirs.ExtSrc   # vsce packages the extension in the current directory
    try {
        & $script:NodeInfo.Npx --yes '@vscode/vsce' package --allow-missing-repository --no-dependencies -o $vsixPath
        if ($LASTEXITCODE -ne 0) { throw "vsce package failed (exit $LASTEXITCODE)" }
    }
    catch {
        Write-Wrn "vsce packaging failed: $($_.Exception.Message)"
        Write-Wrn "Package manually:  cd `"$($Dirs.ExtSrc)`"; npx @vscode/vsce package -o `"$vsixPath`""
        return
    }
    finally { Pop-Location }

    if (-not (Test-Path $vsixPath)) { throw 'vsce reported success but no .vsix was produced' }
    Write-Ok "packaged: $vsixPath"

    $code = Find-VSCodeCli
    if (-not $code) {
        Write-Wrn 'VS Code CLI not found. Install manually with:'
        Write-Wrn "    code --install-extension `"$vsixPath`" --force"
        return
    }
    & $code --install-extension $vsixPath --force
    if ($LASTEXITCODE -ne 0) { throw "code --install-extension failed (exit $LASTEXITCODE)" }
    Write-Ok 'extension installed - reload VS Code windows to activate'
}

# =============================================================================
#  Environment persistence
# =============================================================================
function Get-UnixProfileFiles {
    # zsh is the macOS default shell and does not read ~/.profile.
    $files = @((Join-Path $HOME '.profile'))
    if ($script:OS -eq 'macos') { $files += (Join-Path $HOME '.zprofile') }
    return $files
}

function Persist-UnixEnvLine {
    param([string]$Name, [string]$Value)
    $line = "export $Name=`"$Value`""
    foreach ($profileFile in Get-UnixProfileFiles) {
        $existing = ''
        if (Test-Path $profileFile) { $existing = Get-Content $profileFile -Raw }
        if ($existing -notmatch [regex]::Escape("$Name=")) {
            Add-Content -Path $profileFile -Value $line
            Write-Inf "added to ~/$(Split-Path $profileFile -Leaf): $line"
        }
    }
}

function Persist-UnixPathEntry {
    param([string]$Dir)
    $line = 'export PATH="' + $Dir + ':$PATH"'
    foreach ($profileFile in Get-UnixProfileFiles) {
        $existing = ''
        if (Test-Path $profileFile) { $existing = Get-Content $profileFile -Raw }
        if ($existing -notmatch [regex]::Escape($Dir)) {
            Add-Content -Path $profileFile -Value $line
            Write-Inf "added to ~/$(Split-Path $profileFile -Leaf): $line"
        }
    }
}

function Persist-HomeVar {
    if ($script:OS -eq 'windows') {
        [Environment]::SetEnvironmentVariable('LOCALCODEAI_HOME', $Root, 'User')
    }
    else {
        Persist-UnixEnvLine -Name 'LOCALCODEAI_HOME' -Value $Root
    }
    $env:LOCALCODEAI_HOME = $Root
}

# =============================================================================
#  Main
# =============================================================================
Write-Host ''
Write-Host '  Local Code AI setup' -ForegroundColor White
Write-Host "  Platform: $($script:OS)/$($script:Arch)   Root: $Root" -ForegroundColor Gray
if ($script:OS -ne 'windows') {
    Write-Wrn 'macOS/Linux support is wired but has received less testing than Windows.'
}

foreach ($d in $Dirs.Values) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

Test-Prerequisites
Persist-HomeVar

$ollamaCmd = Ensure-Ollama
$endpoint = Configure-OllamaModelStore -OllamaCmd $ollamaCmd
if (-not $SkipModel) { Ensure-Model -OllamaCmd $ollamaCmd } else { Write-Step 'Skipping model phase (-SkipModel)' }
if (-not $SkipTools) { Ensure-Tools } else { Write-Step 'Skipping tools phase (-SkipTools)' }
if (-not $SkipExtension) {
    Copy-ExtensionSource
    Build-And-InstallExtension
}
else { Write-Step 'Skipping extension phase (-SkipExtension)' }

Write-Step 'Done'
$modelLine = if ($SkipModel) {
    "Model phase skipped (-SkipModel); existing alias '$ModelAlias' (if any) left untouched. Server at $endpoint"
}
else {
    "Model: '$ModelAlias' (from $($script:Tier.Tag), context $($script:Tier.Ctx)) at $endpoint"
}
Write-Host @"

  Everything lives under: $Root
    models      Ollama model store (OLLAMA_MODELS)
    tools       gofumpt, rustfmt, Node+prettier, PSScriptAnalyzer + paths.json
    extension   extension source + local-code-ai.vsix

  In VS Code (after a reload):
    Chat: Ctrl/Cmd+Shift+P -> "Local Code AI: Open Chat"  (opens an editor tab you
          can move or split into any group; the "Local Code AI" activity-bar icon
          still gives you the same chat docked in the side bar)
          The chat sees the open project: it gets a live file list, the open tabs,
          the active editor and the problems, and it can read/search the files
          itself - no more pasting code into the prompt.
    Ctrl/Cmd+Shift+P -> "Local Code AI: Refactor & Format Current File"
    Ctrl/Cmd+Shift+P -> "Local Code AI: Refactor & Format Workspace"
    Ctrl/Cmd+Shift+P -> "Local Code AI: Check Setup (Ollama + tools)"

  Behavior: edits are auto-applied and saved; nothing is git-committed.
  A warning appears when a workspace run would modify more than 50 files.
    -> change it in Settings: localCodeAI.maxFilesBeforeWarning

  $modelLine
  Re-run this script any time; every phase is idempotent.
  Useful flags: -SkipModel -SkipTools -SkipExtension -ModelTag <tag> -Yes -Force

"@ -ForegroundColor White
