# 1. Get all PIDs currently using the NVIDIA GPU
$gpuProcesses = nvidia-smi --query-compute-apps=pid --format=csv,noheader

if ($gpuProcesses) {
    foreach ($GpuPid in $gpuProcesses) {
        # Trim whitespace to ensure the ID is clean
        $GpuPid = $GpuPid.Trim()
        
        $proc = Get-Process -Id $GpuPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "Found: $($proc.Name) (PID: $GpuPid)" -ForegroundColor Yellow
            
            try {
                $appPath = $proc.MainModule.FileName
                $registryPath = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
                
                # 2. Block the app from returning to the High-Performance GPU
                if (!(Test-Path $registryPath)) {
                    New-Item -Path $registryPath -Force | Out-Null
                }
                
                # GpuPreference=1 forces "Power Saving" (Integrated/CPU)
                # GpuPreference=2 forces "High Performance" (NVIDIA)
                Set-ItemProperty -Path $registryPath -Name $appPath -Value "GpuPreference=1;"
                Write-Host " -> Set to Power Saving in Registry." -ForegroundColor Cyan
                
                # 3. Kill the process
                Stop-Process -Id $GpuPid -Force
                Write-Host " -> Process Terminated." -ForegroundColor Green
            } 
            catch {
                Write-Host " -> Could not process $($proc.Name). Access denied?" -ForegroundColor Red
            }
        }
    }
    Write-Host "`nGPU Purge Complete." -ForegroundColor Green
} else {
    Write-Host "No processes found on the GPU." -ForegroundColor Cyan
}