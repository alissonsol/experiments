# Test-NewText.ps1
# VERSION: 0.1
# GUID: 42c2c1d0-e4f5-6789-abcd-ef0123456789
# Tests the Get-NewTextContent function by comparing two consecutive screenshots.

$ErrorActionPreference = 'Stop'
$DebugPreference = 'Continue'  # Show Write-Debug messages
$InformationPreference = 'Continue'  # Show Write-Information messages

$scriptDir = $PSScriptRoot

# Import the module
Import-Module (Join-Path $scriptDir 'Get-NewText') -Force

# Define input paths
$currentScreenPath  = Join-Path -Path $scriptDir -ChildPath 'screenshots' -AdditionalChildPath '0008.png'
$previousScreenPath = Join-Path -Path $scriptDir -ChildPath 'screenshots' -AdditionalChildPath '0007.png'  # Set to $null to test with only the current screen

Write-Information '=== Get-NewTextContent Test ==='
Write-Information ''
Write-Information "Current screen:  $currentScreenPath"
Write-Information "Previous screen: $previousScreenPath"
Write-Information ''

# Run the function
$ocrText = Get-NewTextContent -CurrentScreenPath $currentScreenPath -PreviousScreenPath $previousScreenPath

# Display results
Write-Information ''
Write-Information '=== OCR Output ==='
Write-Output $ocrText
Write-Information ''

# Show debug artifact locations
$tempRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
$debugDir = Join-Path $tempRoot 'NewText'
Write-Information '=== Debug Artifacts ==='
Write-Information "Location: $debugDir"
Get-ChildItem $debugDir | Format-Table Name, Length, LastWriteTime -AutoSize
