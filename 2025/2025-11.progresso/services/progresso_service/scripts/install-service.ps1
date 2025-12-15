<# Copyright (c) 2025 - Alisson Sol #>
param(
    [string]$ExePath = "$(Resolve-Path "..\target\release\progresso_service.exe")",
    [string]$ServiceName = "ProgressoService",
    [string]$DisplayName = "Progresso Service",
    [string]$Description = "Service that processes ordem.target.xml and writes progresso files.",
    [ValidateSet('auto','demand')]
    [string]$StartMode = 'auto'
)

function Find-Nssm {
    $paths = $env:Path -split ';'
    foreach ($p in $paths) {
        $exe = Join-Path $p 'nssm.exe'
        if (Test-Path $exe) { return $exe }
    }
    # also check local tools folder
    $local = Join-Path $PSScriptRoot '..\..\tools\nssm\nssm.exe'
    if (Test-Path $local) { return (Resolve-Path $local).Path }
    return $null
}

Write-Host "Installing service '$ServiceName' for executable path: $ExePath"

if (-not (Test-Path $ExePath)) {
    Write-Error "Executable not found at $ExePath"
    exit 1
}

$nssm = Find-Nssm
if ($nssm) {
    Write-Host "Found nssm at $nssm — using NSSM to create service."
    & $nssm install $ServiceName $ExePath | Out-Null
    & $nssm set $ServiceName DisplayName $DisplayName | Out-Null
    & $nssm set $ServiceName Description $Description | Out-Null
    & $nssm set $ServiceName Start $StartMode | Out-Null
    Write-Host "Starting service $ServiceName"
    & $nssm start $ServiceName
    Write-Host "Service installed (nssm)."
} else {
    Write-Host "nssm not found — falling back to sc.exe."
    $binPath = '"' + (Resolve-Path $ExePath).Path + '"'
    # sc requires a space after the '=' for some args
    sc.exe create $ServiceName binPath= $binPath DisplayName= "$DisplayName" start= auto | Out-Null
    sc.exe description $ServiceName "$Description" | Out-Null
    Write-Host "Starting service $ServiceName"
    sc.exe start $ServiceName | Out-Null
    Write-Host "Service installed (sc create)."
}
