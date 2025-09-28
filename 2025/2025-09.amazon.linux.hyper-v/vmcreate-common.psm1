<#PSScriptInfo
.VERSION 0.1
.GUID e50a15d0-96f6-11f0-a790-b9c7039a859e
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2025 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# --- Define Oscdimg Path (adjust '10' for your ADK version if necessary) ---
$OscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\Oscdimg.exe"

# CreateIso: build an ISO from a source directory using Oscdimg
function CreateIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [string]$VolumeId = "cidata"
    )

    # Resolve current working directory
    $cwd = (Get-Location).ProviderPath

    # Make SourceDir absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($SourceDir)) {
        $SourceDir = Join-Path $cwd $SourceDir
    }
    $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

    if (-not (Test-Path -Path $SourceDir)) {
        Throw "SourceDir not found: $SourceDir"
    }

    # Make OutputFile absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
        $OutputFile = Join-Path $cwd $OutputFile
    }
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)

    # Ensure output directory exists
    $outDir = Split-Path -Path $OutputFile -Parent
    if ($outDir -and -not (Test-Path -Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    if (-not (Test-Path -Path $OscdimgPath)) {
        Throw "Oscdimg.exe not found at path: $OscdimgPath. Install the Windows ADK Deployment Tools or set `-OscdimgPath` to the proper location."
    }

    Write-Information "Creating ISO `nfrom '$SourceDir' `nto '$OutputFile' `nwith Volume ID '$VolumeId'..."
    & $OscdimgPath "$SourceDir" "$OutputFile" -n -h -m -l"$VolumeId"

    Write-Output "ISO created successfully at: $OutputFile"
}
