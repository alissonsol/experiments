# Test script to demonstrate the ordem service diagnostics
# This script will stop any running instance and test the new diagnostics

Write-Host "=== Ordem Service Diagnostics Test ===" -ForegroundColor Cyan
Write-Host ""

# Stop any running ordem_service processes
Write-Host "Stopping any running ordem_service instances..." -ForegroundColor Yellow
Get-Process -Name "ordem_service" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Run the newly built executable with diagnostics
Write-Host ""
Write-Host "Starting ordem service with diagnostics enabled..." -ForegroundColor Green
Write-Host ""

& "services\retrieve\target\x86_64-pc-windows-msvc\release\ordem_service.exe"
