# Copyright (c) 2023 Alisson Sol
# This script is designed for PowerShell Core (PowerShell 6 or later).
# To run, navigate to the script's directory and execute:
# .\WebServer.ps1
# To specify a different port: .\WebServer.ps1 -Port 9000

# Make sure the PowerShell execution policy allows scripts to run.
# You might need to run: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

function Get-MimeType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $mimeTypes = @{
        '.html'  = 'text/html';
        '.htm'   = 'text/html';
        '.css'   = 'text/css';
        '.js'    = 'application/javascript';
        '.json'  = 'application/json';
        '.jpg'   = 'image/jpeg';
        '.jpeg'  = 'image/jpeg';
        '.png'   = 'image/png';
        '.gif'   = 'image/gif';
        '.svg'   = 'image/svg+xml';
        '.txt'   = 'text/plain';
        '.pdf'   = 'application/pdf';
        '.ico'   = 'image/x-icon';
        '.woff'  = 'font/woff';
        '.woff2' = 'font/woff2';
        '.ttf'   = 'font/ttf';
        '.eot'   = 'application/vnd.ms-fontobject';
        '.otf'   = 'font/otf'
    }

    if ($mimeTypes.ContainsKey($extension)) {
        return $mimeTypes[$extension]
    }
    else {
        return 'application/octet-stream' # Default fallback
    }
}

function Start-SimpleWebServer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory = $true)] [string]$ContentPath,
        [Parameter(Mandatory = $false)] [int]$Port = 8080
    )

    Process {
        if ($PSCmdlet.ShouldProcess("Start web server on port $Port serving from $ContentPath")) {
            # Check if the content path exists.
            if (-not (Test-Path -Path $ContentPath -PathType Container)) {
                Write-Error "Content folder not found at '$ContentPath'."
                return
            }

            $uriPrefix = "http://*:$Port/"

            Write-Output "Starting web server..."
            Write-Output "Serving content from: $ContentPath"
            Write-Output "Listening on: http://localhost:$Port/"
            Write-Output "Press Ctrl+C to stop the server."

            try {
                # Create a new HTTP Listener.
                $httpListener = New-Object System.Net.HttpListener
                $httpListener.Prefixes.Add($uriPrefix)
                $httpListener.Start()

                while ($true) {
                    # Get the incoming request.
                    $context = $httpListener.GetContext()
                    $request = $context.Request
                    $response = $context.Response

                    # Determine the requested file path.
                    $relativePath = $request.Url.LocalPath.TrimStart('/')
                    $filePath = Join-Path -Path $ContentPath -ChildPath $relativePath

                    # Handle requests for the root path or empty path by searching for index.html or index.htm
                    if ([string]::IsNullOrEmpty($relativePath) -or $relativePath -eq 'index.html' -or $relativePath -eq 'index.htm') {
                        if (Test-Path -Path (Join-Path -Path $ContentPath -ChildPath 'index.html') -PathType Leaf) {
                            $filePath = Join-Path -Path $ContentPath -ChildPath 'index.html'
                        }
                        elseif (Test-Path -Path (Join-Path -Path $ContentPath -ChildPath 'index.htm') -PathType Leaf) {
                            $filePath = Join-Path -Path $ContentPath -ChildPath 'index.htm'
                        }
                        else {
                            $filePath = $null
                        }
                    }
                    Write-Output "Serving: $filePath"

                    if (Test-Path -Path $filePath -PathType Leaf) {
                        # Read the file and write it to the response stream.
                        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
                        $response.ContentLength64 = $fileBytes.Length

                        # Set the correct MIME type for the file using our custom function.
                        $mimeType = Get-MimeType -FilePath $filePath
                        $response.ContentType = $mimeType

                        $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    }
                    else {
                        # File not found.
                        $response.StatusCode = 404
                        $response.StatusDescription = "Not Found"
                        $notFoundMessage = "<h1>404 Not Found</h1><p>The requested URL was not found on this server: $relativePath</p>"
                        $notFoundBytes = [System.Text.Encoding]::UTF8.GetBytes($notFoundMessage)
                        $response.ContentLength64 = $notFoundBytes.Length
                        $response.OutputStream.Write($notFoundBytes, 0, $notFoundBytes.Length)
                    }
                    $response.Close()
                }
            }
            catch {
                Write-Error $_.Exception.Message
            }
            finally {
                if ($httpListener.IsListening) {
                    $httpListener.Stop()
                    Write-Output "Web server stopped."
                }
            }
        }
    }
}

function Test-Admin {
    try {
        if ($IsWindows) {
            try {
                $wi = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $wp = New-Object System.Security.Principal.WindowsPrincipal($wi)
                return $wp.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
            } catch {
                return $false
            }
        } else {
            # Non-Windows: check for UID 0 (root) via the `id` command; fall back to environment variables
            try {
                if (Get-Command id -ErrorAction SilentlyContinue) {
                    $uid = (& id -u) 2>$null
                    return ($uid -eq '0' -or $uid -eq 0)
                } else {
                    return ($env:USER -eq 'root') -or ($env:USERNAME -eq 'root')
                }
            } catch {
                return $false
            }
        }
    } catch {
        return $false
    }
}

# Get the script's directory.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$contentFolder = Join-Path -Path $scriptDir -ChildPath "content"

if ((Test-Admin) -eq $false) {
    Write-Error "Make sure the PowerShell execution policy allows scripts to run."
    Write-Error "You might need to run: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass"
    Write-Error "Run this script in an elevated PowerShell session (Run as Administrator)."
    exit
}

# Start the server with a default port and allow it to be overridden.
try {
    Start-SimpleWebServer -ContentPath $contentFolder @PSBoundParameters
}
catch {
    Write-Error "Failed to start web server: $_"
}
finally {
    Write-Output "Exiting script."
}

