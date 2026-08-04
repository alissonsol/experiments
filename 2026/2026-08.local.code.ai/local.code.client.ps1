<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42b7d914-3c58-4a06-b1e7-5f2a9c48d310
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 by Alisson Sol.
.TAGS local-ai continue vscode extension client
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
    Local Code AI client - points the Continue VS Code extension at a local server.

.DESCRIPTION
    Prepares a workstation to use the inference server started by
    local.code.server.ps1. Runs on Windows, macOS and Linux.

    What it does, in order:
      1. VS Code ................ locates the 'code' CLI (PATH, then the usual
                                  install locations, then a Flatpak install). When
                                  VS Code is missing it prints platform-specific
                                  install instructions and exits.
      2. Extension .............. installs Continue.continue, or updates it when it
                                  is already there, and reports the version.
      3. Server URL ............. takes -ServerUrl or asks for it, then probes
                                  <url>/v1/models to confirm the server answers and
                                  to learn which models it actually serves.
      4. Configuration .......... writes a Continue assistant that maps those models
                                  to the chat, edit, apply, autocomplete and embed
                                  roles.

    Idempotent: re-running updates the extension and rewrites the assistant file,
    keeping a timestamped backup whenever the previous content differed.

    By default the assistant is written to ~/.continue/assistants/local-code-ai.yaml,
    which Continue loads alongside any existing config.yaml - your own configuration
    is never touched. Use -Scope workspace to write .continue/assistants/ in the
    current folder instead, so the setting travels with the repository.

.PARAMETER ServerUrl
    Base URL printed by local.code.server.ps1, for example http://halo.lan:8888.
    A trailing /v1 is accepted and normalized. Asked for interactively when absent.

.PARAMETER ApiKey
    Value sent as the OpenAI bearer token. The server needs no authentication, but
    Continue requires the field, so the default placeholder is fine.

.PARAMETER Scope
    'global' (default) writes ~/.continue/assistants; 'workspace' writes
    .continue/assistants in the current folder.

.PARAMETER AssistantName
    File name (without extension) and assistant name. Default: local-code-ai.

.PARAMETER SkipExtension
    Do not install or update the extension; only write the configuration.

.PARAMETER Yes
    Non-interactive: auto-accept all confirmation prompts.

.PARAMETER Force
    Write the configuration even when the server cannot be reached.

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\local.code.client.ps1

.EXAMPLE
    pwsh ./local.code.client.ps1 -ServerUrl http://halo.lan:8888

.EXAMPLE
    pwsh ./local.code.client.ps1 -ServerUrl http://halo.lan:8888 -Scope workspace -Yes

.NOTES
    Requires PowerShell 7+ (pwsh) and VS Code.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive console tool: colored status output is intentional. On PowerShell 7 Write-Host writes to the information stream and stays redirectable, and Write-Output would corrupt helper function return values.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'False positive: each of these parameters is consumed inside a function defined later in this script.')]
[CmdletBinding()]
param(
    [string]$ServerUrl = '',
    [string]$ApiKey = 'unused',
    [ValidateSet('global', 'workspace')]
    [string]$Scope = 'global',
    [string]$AssistantName = 'local-code-ai',
    [switch]$SkipExtension,
    [switch]$Yes,
    [switch]$Force
)

# --- PowerShell 7 gate (this file stays parseable by 5.1 so the message shows) ---
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'This script requires PowerShell 7+ (pwsh) for cross-platform support.' -ForegroundColor Red
    Write-Host 'Install it, then re-run:' -ForegroundColor Yellow
    Write-Host '    winget install Microsoft.PowerShell            # Windows'
    Write-Host '    brew install powershell/tap/powershell         # macOS'
    Write-Host '    pwsh -ExecutionPolicy Bypass -File .\local.code.client.ps1'
    exit 1
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Native exit codes are inspected explicitly below; do not let them throw.
$PSNativeCommandUseErrorActionPreference = $false

$script:ExtensionId = 'Continue.continue'

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

function Get-OSKey {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}
$script:OS = Get-OSKey

function Find-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

# =============================================================================
#  1) VS Code
# =============================================================================
# Returns an object describing how to call the CLI: either an executable, or
# Flatpak with the leading 'run <app-id>' arguments.
function Find-VSCodeCli {
    foreach ($name in @('code', 'code-insiders')) {
        $path = Find-CommandPath $name
        if ($path) { return [pscustomobject]@{ Exe = $path; Prefix = @(); Label = $name } }
    }

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
        if ($path -and (Test-Path $path)) { return [pscustomobject]@{ Exe = $path; Prefix = @(); Label = $path } }
    }

    $flatpak = Find-CommandPath 'flatpak'
    if ($flatpak) {
        try {
            $installed = & $flatpak list --app --columns=application 2>$null
            if ($LASTEXITCODE -eq 0 -and ($installed -contains 'com.visualstudio.code')) {
                return [pscustomobject]@{ Exe = $flatpak; Prefix = @('run', 'com.visualstudio.code'); Label = 'flatpak com.visualstudio.code' }
            }
        }
        catch { Write-Debug "flatpak list failed: $_" }
    }
    return $null
}

# Only stdout is captured: merging stderr with 2>&1 would raise a terminating
# NativeCommandError under $ErrorActionPreference = 'Stop'. Diagnostics from the
# CLI go straight to the console instead.
function Invoke-VSCode {
    param([pscustomobject]$Cli, [string[]]$Arguments)
    $all = @($Cli.Prefix) + $Arguments
    return (& $Cli.Exe @all)
}

function Show-VSCodeInstallHelp {
    Write-Bad 'VS Code was not found on this machine.'
    Write-Host ''
    Write-Inf 'Install it, make sure the "code" command is on PATH, then re-run this script:'
    Write-Host ''
    switch ($script:OS) {
        'windows' {
            Write-Host '    winget install Microsoft.VisualStudioCode' -ForegroundColor White
            Write-Inf 'or download from https://code.visualstudio.com/download'
            Write-Inf 'Keep the "Add to PATH" option selected in the installer.'
        }
        'macos' {
            Write-Host '    brew install --cask visual-studio-code' -ForegroundColor White
            Write-Inf 'or download from https://code.visualstudio.com/download'
            Write-Inf 'Then run: Command+Shift+P -> "Shell Command: Install ''code'' command in PATH".'
        }
        default {
            Write-Host '    sudo apt install -y wget gpg' -ForegroundColor White
            Write-Host '    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/ms.gpg' -ForegroundColor White
            Write-Host '    sudo install -D -o root -g root -m 644 /tmp/ms.gpg /usr/share/keyrings/microsoft.gpg' -ForegroundColor White
            Write-Host '    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list' -ForegroundColor White
            Write-Host '    sudo apt update && sudo apt install -y code' -ForegroundColor White
            Write-Inf 'or:  sudo snap install code --classic'
            Write-Inf 'or download from https://code.visualstudio.com/download'
        }
    }
    Write-Host ''
}

function Get-ExtensionVersion {
    param([pscustomobject]$Cli)
    $listed = Invoke-VSCode -Cli $Cli -Arguments @('--list-extensions', '--show-versions')
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $listed) {
        if ("$line" -match "^$([regex]::Escape($script:ExtensionId))@(.+)$") { return $Matches[1].Trim() }
    }
    return $null
}

function Install-ContinueExtension {
    param([pscustomobject]$Cli)
    Write-Step 'Continue extension'
    $before = Get-ExtensionVersion -Cli $Cli
    if ($before) { Write-Inf "installed: $($script:ExtensionId) $before - checking for updates" }
    else { Write-Inf "installing $($script:ExtensionId)" }

    $output = Invoke-VSCode -Cli $Cli -Arguments @('--install-extension', $script:ExtensionId, '--force')
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "code --install-extension failed (exit $LASTEXITCODE)"
        foreach ($line in $output) { Write-Inf "  $line" }
        throw "could not install $($script:ExtensionId)"
    }

    $after = Get-ExtensionVersion -Cli $Cli
    if (-not $after) { Write-Wrn 'the extension is not in the list; check the VS Code output above' }
    elseif (-not $before) { Write-Ok "$($script:ExtensionId) $after installed" }
    elseif ($after -ne $before) { Write-Ok "$($script:ExtensionId) $before -> $after" }
    else { Write-Ok "$($script:ExtensionId) $after (already up to date)" }
}

# =============================================================================
#  2) Server URL
# =============================================================================
function Get-NormalizedServerUrl {
    param([string]$Value)
    $text = "$Value".Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if ($text -notmatch '^https?://') { $text = "http://$text" }
    if ($text -match '/v1$') { $text = $text.Substring(0, $text.Length - 3).TrimEnd('/') }
    try {
        $uri = [uri]$text
        if (-not $uri.IsAbsoluteUri) { return $null }
    }
    catch { return $null }
    return $text
}

function Read-ServerUrl {
    Write-Step 'Server URL'
    if ($ServerUrl) {
        $normalized = Get-NormalizedServerUrl $ServerUrl
        if (-not $normalized) { throw "'$ServerUrl' is not a valid URL" }
        Write-Ok "using $normalized"
        return $normalized
    }
    Write-Inf 'This is the URL printed by local.code.server.ps1 on the server machine,'
    Write-Inf 'for example http://192.168.1.50:8888 or http://halo.lan:8888.'
    while ($true) {
        $answer = Read-Host '    Server URL [http://localhost:8888]'
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'http://localhost:8888' }
        $normalized = Get-NormalizedServerUrl $answer
        if ($normalized) { return $normalized }
        Write-Wrn "'$answer' is not a valid URL, try again"
    }
}

function Get-ServerModel {
    param([string]$BaseUrl)
    try {
        $headers = @{}
        if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }
        $response = Invoke-RestMethod -Uri "$BaseUrl/v1/models" -TimeoutSec 15 -Headers $headers
        return @($response.data | ForEach-Object { $_.id })
    }
    catch {
        Write-Wrn "could not reach $BaseUrl/v1/models - $($_.Exception.Message)"
        return $null
    }
}

# =============================================================================
#  3) Continue assistant
# =============================================================================
# Role map for the models served by local.code.server.ps1. Entries whose model is
# not offered by the server are skipped.
#
# Caps becomes Continue's 'capabilities' list. Declaring 'tool_use' is what makes
# Agent mode able to edit files, and it is NOT optional here. Continue decides
# tool support for provider 'openai' by string-matching the model id
# (core/llm/toolSupport.ts): it accepts /^gpt-[4-9]/, /^o[1-9]/, 'codex', and the
# substrings 'gpt-oss', 'exaone', 'gemma', and otherwise returns false. Our ids are
# llama-swap aliases - 'interactive', 'deep-reviewer', 'second-opinion' - so every
# one of them falls through to false, however capable the model behind it actually
# is. Continue then silently downgrades Agent mode to a text-imitation protocol: it
# stops sending a tools array and instead asks the model to type a TOOL_NAME: /
# BEGIN_ARG fence as prose. Local models reproduce that fence unreliably, so the
# edit is described and never written, which is exactly what we saw. An explicit
# capabilities list short-circuits the name check and restores real tool calls -
# verified against this server, which returns correct tool_calls both buffered and
# streamed. Only chat models get it; FIM and embeddings have no tool surface.
$script:ModelSpec = @(
    [pscustomobject]@{
        Id      = 'interactive'
        Title   = 'Local Fast (Qwen3-Coder 30B)'
        Roles   = @('chat', 'edit', 'apply')
        Caps    = @('tool_use')
        Options = [ordered]@{ contextLength = 65536; maxTokens = 8192; temperature = 0.15 }
        Legacy  = $false
    }
    [pscustomobject]@{
        Id      = 'deep-reviewer'
        Title   = 'Local Deep review (gpt-oss-120b)'
        # 'apply' as well as 'edit'. Continue resolves the writer as
        # selectedModelByRole.apply ?? selectedModelByRole.chat, so without an apply
        # role anywhere on the selected model the 120B reasoning model performs the
        # merge itself - the slowest and least suitable model for a mechanical
        # diff, and the reason the earlier attempt corrupted the file footer.
        Roles   = @('chat', 'edit', 'apply')
        Caps    = @('tool_use')
        Options = [ordered]@{ contextLength = 65536; maxTokens = 16384; temperature = 0.2 }
        Legacy  = $false
    }
    [pscustomobject]@{
        Id      = 'second-opinion'
        Title   = 'Local Cross-check (GLM-4.5-Air)'
        Roles   = @('chat')
        Caps    = @('tool_use')
        Options = [ordered]@{ contextLength = 65536 }
        Legacy  = $false
    }
    [pscustomobject]@{
        Id      = 'code-fim'
        Title   = 'Local Autocomplete (Qwen2.5-Coder 3B)'
        Roles   = @('autocomplete')
        Caps    = $null
        Options = $null
        Legacy  = $true          # FIM needs the raw completions endpoint, not chat
    }
    [pscustomobject]@{
        Id      = 'code-embed'
        Title   = 'Local Embeddings (Qwen3-Embedding 0.6B)'
        Roles   = @('embed')
        Caps    = $null
        Options = $null
        Legacy  = $false
    }
)

function ConvertTo-YamlScalar {
    param($Value)
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    return '"' + ("$Value" -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Get-AssistantYaml {
    param([string]$BaseUrl, [string[]]$AvailableIds)

    $apiBase = "$BaseUrl/v1"
    $builder = [System.Text.StringBuilder]::new()
    $add = { param([string]$Line) $null = $builder.AppendLine($Line) }

    & $add '# Generated by local.code.client.ps1 - rewritten on every run.'
    & $add "# Server: $BaseUrl (llama.cpp + llama-swap, OpenAI-compatible)"
    & $add ('name: ' + (ConvertTo-YamlScalar $AssistantName))
    & $add 'version: 1.0.0'
    & $add 'schema: v1'
    & $add ''
    & $add 'models:'

    $written = 0
    foreach ($spec in $script:ModelSpec) {
        if ($AvailableIds -and ($AvailableIds -notcontains $spec.Id)) {
            Write-Inf "skipping '$($spec.Id)': the server does not offer it"
            continue
        }
        $written++
        & $add ('  - name: ' + (ConvertTo-YamlScalar $spec.Title))
        & $add '    provider: openai'
        & $add ('    model: ' + $spec.Id)
        & $add ('    apiBase: ' + (ConvertTo-YamlScalar $apiBase))
        & $add ('    apiKey: ' + (ConvertTo-YamlScalar $ApiKey))
        & $add ('    roles: [' + ($spec.Roles -join ', ') + ']')
        if ($spec.Caps) { & $add ('    capabilities: [' + ($spec.Caps -join ', ') + ']') }
        if ($spec.Legacy) { & $add '    useLegacyCompletionsEndpoint: true' }
        if ($spec.Options) {
            & $add '    defaultCompletionOptions:'
            foreach ($key in $spec.Options.Keys) {
                & $add ('      ' + $key + ': ' + (ConvertTo-YamlScalar $spec.Options[$key]))
            }
        }
    }
    if ($written -eq 0) { throw 'the server offers none of the expected models; nothing to configure' }

    & $add ''
    & $add 'context:'
    & $add '  - provider: code'
    & $add '  - provider: diff'
    & $add '  - provider: codebase'
    & $add '  - provider: problems'

    return $builder.ToString()
}

function Save-Assistant {
    param([string]$Text)
    Write-Step 'Continue configuration'
    if ($Scope -eq 'workspace') { $root = Join-Path (Get-Location).Path '.continue' }
    else { $root = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.continue' }
    $folder = Join-Path $root 'assistants'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $target = Join-Path $folder "$AssistantName.yaml"

    if (Test-Path $target) {
        $existing = Get-Content -Raw -Path $target
        if ($existing -eq $Text) {
            Write-Ok "$target (unchanged)"
            return $target
        }
        $backup = "$target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $target -Destination $backup -Force
        Write-Inf "previous version kept as $backup"
    }
    [System.IO.File]::WriteAllText($target, $Text, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "$target written"
    return $target
}

# =============================================================================
#  Main
# =============================================================================
Write-Host ''
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Cyan
Write-Host '|  Local Code AI - client (VS Code + Continue.continue)          |' -ForegroundColor Cyan
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Cyan

Write-Step 'VS Code'
$cli = Find-VSCodeCli
if (-not $cli) {
    Show-VSCodeInstallHelp
    exit 1
}
Write-Ok "VS Code CLI: $($cli.Label)"

if ($SkipExtension) { Write-Inf '-SkipExtension: leaving the extension untouched' }
else { Install-ContinueExtension -Cli $cli }

$baseUrl = Read-ServerUrl
$availableIds = Get-ServerModel -BaseUrl $baseUrl
if ($null -eq $availableIds) {
    Write-Wrn 'the configuration will list all five models of the reference server'
    if (-not $Force -and -not (Confirm-Continue '    Write the configuration anyway?')) {
        Write-Host ''
        Write-Inf 'Nothing was written. Start the server, then re-run:'
        Write-Inf '    pwsh ./local.code.server.ps1 -Status       # on the server machine'
        Write-Host ''
        exit 1
    }
}
elseif ($availableIds.Count -eq 0) {
    Write-Wrn 'the server answered but lists no models; configuring all five of the reference server'
}
else {
    Write-Ok "server models: $($availableIds -join ', ')"
}

$yaml = Get-AssistantYaml -BaseUrl $baseUrl -AvailableIds $availableIds
$target = Save-Assistant -Text $yaml

Write-Host ''
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Green
Write-Host '|  Client configured                                            |' -ForegroundColor Green
Write-Host '+---------------------------------------------------------------+' -ForegroundColor Green
Write-Inf "assistant : $target"
Write-Inf "server    : $baseUrl/v1"
Write-Host ''
Write-Inf 'In VS Code:'
Write-Inf "  1. Reload the window (Ctrl/Cmd+Shift+P -> 'Developer: Reload Window')."
Write-Inf '  2. Open the Continue side bar.'
Write-Inf "  3. In the top right, in the list of configurations, select"
Write-Inf "     `"$AssistantName.yaml`" instead of `"Main Config`"."
Write-Inf '  4. Then choose a model in the model selector below the input box.'
Write-Host ''
