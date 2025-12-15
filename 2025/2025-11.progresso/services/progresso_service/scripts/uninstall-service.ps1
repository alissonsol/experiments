<# Copyright (c) 2025 - Alisson Sol #>
param(
    [string]$ServiceName = "ProgressoService"
)

Write-Host "Stopping and removing service '$ServiceName'"

function Find-Nssm {
    $paths = $env:Path -split ';'
    foreach ($p in $paths) {
        $exe = Join-Path $p 'nssm.exe'
        if (Test-Path $exe) { return $exe }
    }
    $local = Join-Path $PSScriptRoot '..\..\tools\nssm\nssm.exe'
    if (Test-Path $local) { return (Resolve-Path $local).Path }
    return $null
}

$nssm = Find-Nssm
if ($nssm) {
    Write-Host "Found nssm at $nssm — stopping and removing via nssm."
    & $nssm stop $ServiceName | Out-Null
    & $nssm remove $ServiceName confirm | Out-Null
    Write-Host "Service removed (nssm)."
} else {
    Write-Host "nssm not found — using sc.exe to stop and delete."
    sc.exe stop $ServiceName | Out-Null
    sc.exe delete $ServiceName | Out-Null
    Write-Host "Service removed (sc delete)."
}
