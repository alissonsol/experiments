# Get-NewText.psm1
# VERSION: 0.1
# GUID: 42a2c1d0-e4f5-6789-abcd-ef0123456789

# --- Platform-specific image processing setup ---
# System.Drawing.Common on .NET 8+/9 only supports Windows.
# On macOS/Linux, ImageMagick (magick) is used instead.

$script:UseImageMagick = -not $IsWindows

if (-not $script:UseImageMagick) {
    # Windows: load System.Drawing and compile C# pixel processor
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -AssemblyName System.Drawing.Common
    } else {
        Add-Type -AssemblyName System.Drawing
    }

    $referencedAssemblies = @(
        [System.Drawing.Bitmap],
        [System.Drawing.Color],
        [System.Drawing.Rectangle],
        [System.Drawing.Imaging.PixelFormat],
        [System.Drawing.Imaging.ImageLockMode],
        [System.Drawing.Imaging.BitmapData]
    ) | ForEach-Object { $_.Assembly.Location } |
        Where-Object { $_ -and (Test-Path $_) } |
        Select-Object -Unique

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
}

# --- Tesseract helper (shared by both paths) ---

function Find-Tesseract {
    $tesseractPath = (Get-Command tesseract -ErrorAction SilentlyContinue).Source
    if (-not $tesseractPath) {
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
    return $tesseractPath
}

# --- ImageMagick path (macOS/Linux) ---

function Invoke-ImageMagickDelta {
    param(
        [string]$CurrentScreenPath,
        [string]$PreviousScreenPath,
        [string]$DebugDir
    )

    $magickPath = (Get-Command magick -ErrorAction SilentlyContinue).Source
    if (-not $magickPath) {
        throw 'ImageMagick not found. Install it (brew install imagemagick) and add to PATH.'
    }

    Write-Debug "Using ImageMagick at: $magickPath"

    # Copy current screen as debug artifact
    Copy-Item -Path $CurrentScreenPath -Destination (Join-Path $DebugDir 'CurrentScreen.png') -Force

    if ([string]::IsNullOrEmpty($PreviousScreenPath)) {
        Write-Debug "No previous screen provided; treating entire image as new."
        Copy-Item -Path $CurrentScreenPath -Destination (Join-Path $DebugDir 'ocr_input.png') -Force
        return Join-Path $DebugDir 'ocr_input.png'
    }

    Copy-Item -Path $PreviousScreenPath -Destination (Join-Path $DebugDir 'PreviousScreen.png') -Force

    # Create pixel-difference image (absolute per-channel difference)
    $deltaPath = Join-Path $DebugDir 'delta.png'
    & $magickPath composite $CurrentScreenPath $PreviousScreenPath -compose difference $deltaPath 2>$null

    # Create a binary mask and get bounding box of changed pixels
    # -format '%@' returns the trim bounding box as WxH+X+Y
    $trimInfo = & $magickPath convert $deltaPath -threshold 0 -format '%@' info: 2>$null
    Write-Debug "Trim bounding box: $trimInfo"

    if (-not $trimInfo -or $trimInfo -match '^0x0') {
        Write-Debug "No pixel changes detected between frames."
        '' | Set-Content -Path (Join-Path $DebugDir 'OcrResult.txt') -Encoding UTF8
        return $null
    }

    # Crop the current image to the bounding box of changed region
    $croppedPath = Join-Path $DebugDir 'ocr_input.png'
    & $magickPath convert $CurrentScreenPath -crop $trimInfo +repage $croppedPath 2>$null

    # Save processed text screen debug artifact (delta thresholded)
    & $magickPath convert $deltaPath -threshold 0 (Join-Path $DebugDir 'ProcessedTextScreen.png') 2>$null

    Write-Debug "Cropped image saved for OCR: $croppedPath"
    return $croppedPath
}

# --- System.Drawing path (Windows) ---

function Invoke-DrawingDelta {
    param(
        [string]$CurrentScreenPath,
        [string]$PreviousScreenPath,
        [string]$DebugDir,
        [System.Drawing.Color]$BackgroundColor
    )

    $currentBmp = $null
    $previousBmp = $null
    $textBmp = $null
    $croppedBmp = $null
    $graphics = $null

    try {
        Write-Debug "Loading current screen from: $CurrentScreenPath"
        $currentBmp = [System.Drawing.Bitmap]::new($CurrentScreenPath)

        $width = $currentBmp.Width
        $height = $currentBmp.Height

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

        if ($currentBmp.Width -ne $previousBmp.Width -or $currentBmp.Height -ne $previousBmp.Height) {
            throw "Image dimensions do not match. Current: ${width}x${height}, Previous: $($previousBmp.Width)x$($previousBmp.Height)."
        }

        Write-Debug "Image dimensions: ${width}x${height}"

        $textBmp = [System.Drawing.Bitmap]::new($width, $height)

        Write-Debug "Running compiled pixel delta extraction..."
        $delta = [ScreenDelta]::ProcessDelta($currentBmp, $previousBmp, $textBmp, $BackgroundColor)

        # Save debug artifacts
        $currentBmp.Save((Join-Path $DebugDir 'CurrentScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $previousBmp.Save((Join-Path $DebugDir 'PreviousScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $textBmp.Save((Join-Path $DebugDir 'ProcessedTextScreen.png'), [System.Drawing.Imaging.ImageFormat]::Png)

        if (-not $delta.HasChanges) {
            Write-Debug "No pixel changes detected between frames."
            '' | Set-Content -Path (Join-Path $DebugDir 'OcrResult.txt') -Encoding UTF8
            return $null
        }

        Write-Debug "Changes detected in rows $($delta.MinY)..$($delta.MaxY) of $height"

        $croppedBmp = [ScreenDelta]::Crop($textBmp, $delta.MinY, $delta.MaxY)
        Write-Debug "Cropped to $($croppedBmp.Width)x$($croppedBmp.Height) for OCR"

        $tempImagePath = Join-Path $DebugDir 'ocr_input.png'
        $croppedBmp.Save($tempImagePath, [System.Drawing.Imaging.ImageFormat]::Png)
        return $tempImagePath
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

# --- Public function ---

function Get-NewTextContent {
    <#
    .SYNOPSIS
        Extracts new text from a screen capture by diffing against a previous frame and running OCR.

    .DESCRIPTION
        Compares two bitmap images pixel-by-pixel to isolate newly appeared content.
        Unchanged pixels are replaced with the background color, and the result is
        cropped to the bounding box of changed rows before being passed to Tesseract
        OCR for text extraction.

        On Windows, pixel processing is performed in compiled C# for performance.
        On macOS/Linux, ImageMagick is used for image processing.
        Requires PowerShell 7+.

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

    # Use cross-platform temp directory
    $tempRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
    $debugDir = Join-Path $tempRoot 'NewText'
    if (-not (Test-Path $debugDir)) {
        New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
    }

    try {
        # Run platform-specific image delta processing; returns path to cropped OCR input or $null
        if ($script:UseImageMagick) {
            $ocrInputPath = Invoke-ImageMagickDelta -CurrentScreenPath $CurrentScreenPath `
                -PreviousScreenPath $PreviousScreenPath -DebugDir $debugDir
        } else {
            $BackgroundColor = [System.Drawing.Color]::Black
            $ocrInputPath = Invoke-DrawingDelta -CurrentScreenPath $CurrentScreenPath `
                -PreviousScreenPath $PreviousScreenPath -DebugDir $debugDir -BackgroundColor $BackgroundColor
        }

        if (-not $ocrInputPath) {
            return ''
        }

        # Run Tesseract OCR on the cropped image
        $tesseractPath = Find-Tesseract
        Write-Debug "Using Tesseract at: $tesseractPath"

        Write-Debug "Running Tesseract OCR..."
        try {
            $ocrOutput = & $tesseractPath $ocrInputPath stdout 2>$null
            $ocrText = ($ocrOutput -join "`n").Trim()
        }
        catch {
            throw "Tesseract OCR execution failed: $_"
        }
        finally {
            if (Test-Path $ocrInputPath) {
                Remove-Item $ocrInputPath -Force
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
}

Export-ModuleMember -Function Get-NewTextContent
