# by Alisson Sol (c) 2020 - No guaranties
$HomeDrive = [System.Environment]::GetEnvironmentVariable("HOMEDRIVE")
$EmailFolder = Resolve-Path -Path (Join-Path -Path $HomeDrive -ChildPath "email")
if ([string]::IsNullOrEmpty($EmailFolder)) { Write-Information "Email folder not found: $EmailFolder"; return $false; }

# Close Outlook
$Process        = "outlook*"
$OutlookProc = Get-Process -Name $Process

if ($OutlookProc){
    # While loop makes sure all outlook windows are closed
    while ($OutlookProc) {
        ForEach ($Proc in Get-Process -Name $Process) {
            $Proc.CloseMainWindow()
        }
        Start-Sleep 5
        If (Get-Process -Name $Process){
            Write-Output "Outlook is Open.......Closing Outlook"
            $wshell = new-object -com wscript.shell
            $wshell.AppActivate("Microsoft Outlook")
            $wshell.Sendkeys("%(Y)")
        }
        $OutlookProc = Get-Process -Name $Process
    }
}

# Copy Outlook folder
$LocalAppData = [System.Environment]::GetEnvironmentVariable("LOCALAPPDATA")
$OutlookAppData = Resolve-Path -Path (Join-Path -Path $LocalAppData -ChildPath "Microsoft/Outlook")
if ([string]::IsNullOrEmpty($OutlookAppData)) { Write-Information "Outlook app data folder not found: $OutlookAppData"; return $false; }
$OutlookBackup = Join-Path -Path $EmailFolder -ChildPath "Outlook"
Remove-Item $OutlookBackup -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Force -Path $OutlookBackup -ErrorAction SilentlyContinue
$OutlookBackup = Resolve-Path -Path $OutlookBackup
if ([string]::IsNullOrEmpty($OutlookBackup)) { Write-Information "Outlook backup folder not clean: $OutlookBackup"; return $false; }
Copy-Item "$OutlookAppData/*" -Destination $OutlookBackup -Recurse -Container -ErrorAction SilentlyContinue

# Now for the backup...
Add-Type -assembly "system.io.compression.filesystem"
$backupFolder = [System.Environment]::CurrentDirectory
$emailHomeFile = Join-Path -Path $backupFolder -ChildPath "email.Home.zip"
Remove-Item $emailHomeFile -Force -ErrorAction SilentlyContinue
[io.compression.zipfile]::CreateFromDirectory($EmailFolder, $emailHomeFile)
