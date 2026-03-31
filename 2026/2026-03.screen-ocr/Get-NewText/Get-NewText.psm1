# Get-NewText.psm1
# VERSION: 0.1
# GUID: 42a2c1d0-e4f5-6789-abcd-ef0123456789

# Load System.Drawing assemblies (cross-platform)
if ($PSVersionTable.PSEdition -eq 'Core') {
    # PowerShell 7+ / .NET Core: System.Drawing.Common is needed.
    # On macOS, also requires: brew install mono-libgdiplus
    Add-Type -AssemblyName System.Drawing.Common
} else {
    Add-Type -AssemblyName System.Drawing
}

# Resolve assembly references for C# compilation.
# .NET Core splits types across many assemblies; collect all that the C# code needs.
$referencedAssemblies = @(
    [System.Drawing.Bitmap],
    [System.Drawing.Color],
    [System.Drawing.Rectangle],
    [System.Drawing.Imaging.PixelFormat],
    [System.Drawing.Imaging.ImageLockMode],
    [System.Drawing.Imaging.BitmapData],
    [System.Runtime.InteropServices.Marshal]
) | ForEach-Object { $_.Assembly.Location } | Select-Object -Unique

# C# source for pixel processing (runs 100-1000x faster than PowerShell loops)
$screenDeltaSource = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class ScreenDelta
{
    public struct DeltaResult
    {
        public int MinY;
        public int MaxY;
        public bool HasChanges;
    }

    /// <summary>
    /// Compares current and previous bitmaps pixel-by-pixel.
    /// Writes the delta into textBmp: unchanged pixels become background,
    /// changed rows are fully recovered from currentBmp.
    /// Returns the vertical bounding box of changed rows for cropping.
    /// </summary>
    public static DeltaResult ProcessDelta(Bitmap currentBmp, Bitmap previousBmp, Bitmap textBmp, Color bgColor)
    {
        int width = currentBmp.Width;
        int height = currentBmp.Height;
        var rect = new Rectangle(0, 0, width, height);
        var fmt = PixelFormat.Format32bppArgb;

        byte bgB = bgColor.B;
        byte bgG = bgColor.G;
        byte bgR = bgColor.R;
        byte bgA = bgColor.A;

        var curData  = currentBmp.LockBits(rect, ImageLockMode.ReadOnly, fmt);
        var prevData = previousBmp.LockBits(rect, ImageLockMode.ReadOnly, fmt);
        var txtData  = textBmp.LockBits(rect, ImageLockMode.ReadWrite, fmt);

        try
        {
            int stride = curData.Stride;
            int bufferSize = stride * height;
            int bytesPerRow = width * 4;

            byte[] curBytes  = new byte[bufferSize];
            byte[] prevBytes = new byte[bufferSize];
            byte[] txtBytes  = new byte[bufferSize];

            Marshal.Copy(curData.Scan0, curBytes, 0, bufferSize);
            Marshal.Copy(prevData.Scan0, prevBytes, 0, bufferSize);

            bool[] rowHasChange = new bool[height];

            // Pass 1: pixel delta
            for (int y = 0; y < height; y++)
            {
                int rowOffset = y * stride;
                bool changed = false;
                for (int x = 0; x < bytesPerRow; x += 4)
                {
                    int i = rowOffset + x;
                    if (curBytes[i]     == prevBytes[i]     &&
                        curBytes[i + 1] == prevBytes[i + 1] &&
                        curBytes[i + 2] == prevBytes[i + 2] &&
                        curBytes[i + 3] == prevBytes[i + 3])
                    {
                        // Same pixel: set to background color (BGRA order)
                        txtBytes[i]     = bgB;
                        txtBytes[i + 1] = bgG;
                        txtBytes[i + 2] = bgR;
                        txtBytes[i + 3] = bgA;
                    }
                    else
                    {
                        txtBytes[i]     = curBytes[i];
                        txtBytes[i + 1] = curBytes[i + 1];
                        txtBytes[i + 2] = curBytes[i + 2];
                        txtBytes[i + 3] = curBytes[i + 3];
                        changed = true;
                    }
                }
                rowHasChange[y] = changed;
            }

            // Pass 2: row recovery and bounding box
            int minY = height;
            int maxY = -1;
            for (int y = 0; y < height; y++)
            {
                if (rowHasChange[y])
                {
                    int rowOffset = y * stride;
                    Buffer.BlockCopy(curBytes, rowOffset, txtBytes, rowOffset, bytesPerRow);
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }

            Marshal.Copy(txtBytes, 0, txtData.Scan0, bufferSize);

            var result = new DeltaResult();
            result.HasChanges = (maxY >= 0);
            result.MinY = minY;
            result.MaxY = maxY;
            return result;
        }
        finally
        {
            textBmp.UnlockBits(txtData);
            previousBmp.UnlockBits(prevData);
            currentBmp.UnlockBits(curData);
        }
    }

    /// <summary>
    /// Crops a bitmap to the specified row range (full width).
    /// </summary>
    public static Bitmap Crop(Bitmap source, int minY, int maxY)
    {
        int cropHeight = maxY - minY + 1;
        var cropRect = new Rectangle(0, minY, source.Width, cropHeight);
        return source.Clone(cropRect, source.PixelFormat);
    }
}
'@

# Only compile if the type is not already loaded in this session.
# If the C# signature changes, restart the PowerShell session to pick up the new version.
if (-not ([System.Management.Automation.PSTypeName]'ScreenDelta').Type) {
    Add-Type -Language CSharp -TypeDefinition $screenDeltaSource -ReferencedAssemblies $referencedAssemblies
}

function Get-NewTextContent {
    <#
    .SYNOPSIS
        Extracts new text from a screen capture by diffing against a previous frame and running OCR.

    .DESCRIPTION
        Compares two bitmap images pixel-by-pixel to isolate newly appeared content.
        Unchanged pixels are replaced with the internal background color, and rows
        containing any change are fully recovered from the current frame to preserve
        OCR quality. The result is cropped to the bounding box of changed rows before
        being passed to Tesseract OCR for text extraction.

        Pixel processing is performed in compiled C# for performance.
        Requires PowerShell 7+. On macOS, also install libgdiplus:
        brew install mono-libgdiplus.

    .PARAMETER CurrentScreenPath
        Path to the current screen capture bitmap file.

    .PARAMETER PreviousScreenPath
        Optional path to the previous screen capture bitmap file. If omitted, a blank
        background image is used as the reference, treating all content as new.

    .OUTPUTS
        System.String. The text extracted by Tesseract OCR from the processed image.

    .EXAMPLE
        Get-NewTextContent -CurrentScreenPath '.\screenshots\0002.png' -PreviousScreenPath '.\screenshots\0001.png'

    .EXAMPLE
        Get-NewTextContent -CurrentScreenPath '.\screenshots\0001.png'
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CurrentScreenPath,

        [Parameter(Mandatory=$false)]
        [string]$PreviousScreenPath
    )

    $BackgroundColor = [System.Drawing.Color]::Black

    # Use cross-platform temp directory
    $tempRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
    $debugDir = Join-Path $tempRoot 'NewText'
    if (-not (Test-Path $debugDir)) {
        New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
    }

    $currentBmp = $null
    $previousBmp = $null
    $textBmp = $null
    $croppedBmp = $null
    $graphics = $null

    try {
        # Load current screen
        Write-Debug "Loading current screen from: $CurrentScreenPath"
        $currentBmp = [System.Drawing.Bitmap]::new($CurrentScreenPath)

        $width = $currentBmp.Width
        $height = $currentBmp.Height

        # Load or create previous screen
        if ([string]::IsNullOrEmpty($PreviousScreenPath)) {
            Write-Debug "No previous screen provided; creating blank background."
            $previousBmp = [System.Drawing.Bitmap]::new($width, $height)
            $graphics = [System.Drawing.Graphics]::FromImage($previousBmp)
            $graphics.Clear($BackgroundColor)
            $graphics.Dispose()
            $graphics = $null
        } else {
            Write-Debug "Loading previous screen from: $PreviousScreenPath"
            $previousBmp = [System.Drawing.Bitmap]::new($PreviousScreenPath)
        }

        # Dimension validation
        if ($currentBmp.Width -ne $previousBmp.Width -or $currentBmp.Height -ne $previousBmp.Height) {
            throw "Image dimensions do not match. Current: ${width}x${height}, Previous: $($previousBmp.Width)x$($previousBmp.Height)."
        }

        Write-Debug "Image dimensions: ${width}x${height}"

        # Create text screen bitmap and run compiled C# delta processing
        $textBmp = [System.Drawing.Bitmap]::new($width, $height)

        Write-Debug "Running compiled pixel delta extraction..."
        $delta = [ScreenDelta]::ProcessDelta($currentBmp, $previousBmp, $textBmp, $BackgroundColor)

        if (-not $delta.HasChanges) {
            Write-Debug "No pixel changes detected between frames."
            # Save debug artifacts even when empty
            $currentBmp.Save((Join-Path $debugDir 'CurrentScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
            $previousBmp.Save((Join-Path $debugDir 'PreviousScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
            $textBmp.Save((Join-Path $debugDir 'ProcessedTextScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
            '' | Set-Content -Path (Join-Path $debugDir 'OcrResult.txt') -Encoding UTF8
            return ''
        }

        Write-Debug "Changes detected in rows $($delta.MinY)..$($delta.MaxY) of $height"

        # Crop to bounding box of changed rows (smaller image = faster OCR)
        $croppedBmp = [ScreenDelta]::Crop($textBmp, $delta.MinY, $delta.MaxY)
        Write-Debug "Cropped to $($croppedBmp.Width)x$($croppedBmp.Height) for OCR"

        # Save debug artifacts
        Write-Debug "Saving debug artifacts to: $debugDir"
        $currentBmp.Save((Join-Path $debugDir 'CurrentScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $previousBmp.Save((Join-Path $debugDir 'PreviousScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $textBmp.Save((Join-Path $debugDir 'ProcessedTextScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)

        # Locate Tesseract
        $tesseractPath = (Get-Command tesseract -ErrorAction SilentlyContinue).Source
        if (-not $tesseractPath) {
            # Check common install locations
            $candidates = @(
                'C:\Program Files\Tesseract-OCR\tesseract.exe'
                '/usr/local/bin/tesseract'
                '/opt/homebrew/bin/tesseract'
            )
            foreach ($candidate in $candidates) {
                if (Test-Path $candidate) {
                    $tesseractPath = $candidate
                    break
                }
            }
        }
        if (-not $tesseractPath) {
            throw 'Tesseract OCR not found. Install it and add to PATH, or place it in a standard location.'
        }
        Write-Debug "Using Tesseract at: $tesseractPath"

        # Save cropped image for OCR
        $tempImagePath = Join-Path $debugDir 'ocr_input.png'
        $croppedBmp.Save($tempImagePath, [System.Drawing.Imaging.ImageFormat]::Png)

        Write-Debug "Running Tesseract OCR..."
        try {
            $ocrOutput = & $tesseractPath $tempImagePath stdout 2>$null
            $ocrText = ($ocrOutput -join "`n").Trim()
        }
        catch {
            throw "Tesseract OCR execution failed: $_"
        }
        finally {
            if (Test-Path $tempImagePath) {
                Remove-Item $tempImagePath -Force
            }
        }

        # Save OCR result
        $ocrText | Set-Content -Path (Join-Path $debugDir 'OcrResult.txt') -Encoding UTF8

        Write-Debug "OCR complete. Extracted $($ocrText.Length) characters."

        return $ocrText
    }
    catch {
        Write-Error "Get-NewTextContent failed: $_"
        throw
    }
    finally {
        if ($graphics)    { $graphics.Dispose() }
        if ($croppedBmp)  { $croppedBmp.Dispose() }
        if ($textBmp)     { $textBmp.Dispose() }
        if ($previousBmp) { $previousBmp.Dispose() }
        if ($currentBmp)  { $currentBmp.Dispose() }
        Write-Debug "All bitmap resources disposed."
    }
}

Export-ModuleMember -Function Get-NewTextContent
