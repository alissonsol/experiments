param (
    [Parameter(Mandatory = $true)]
    [string]$FolderPath
)

# Check if the folder exists
if (-Not (Test-Path -Path $FolderPath -PathType Container)) {
    Write-Output "The folder '$FolderPath' does not exist." -ForegroundColor Red
    exit 1
}

# Recursively enumerate and rename all folders
Get-ChildItem -Path $FolderPath -Directory -Recurse | Sort-Object -Property FullName -Descending | ForEach-Object {
    $originalPath = $_.FullName
    $parentPath = Split-Path $originalPath -Parent
    $lowercaseName = $_.Name.ToLower()
    $lowercasePath = Join-Path $parentPath $lowercaseName
    $tempPath = $lowercasePath + "_temp"

    if ($originalPath -cne $lowercasePath) {
        try {
            Rename-Item -Path $originalPath -NewName $tempPath
            Rename-Item -Path $tempPath -NewName $lowercasePath
            Write-Output "Renamed: $originalPath -> $lowercasePath"
        } catch {
            Write-Output "Failed to rename: $originalPath" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Output "No change: $originalPath"
    }
}