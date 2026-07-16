# screen-ocr

Copyright (c) 2026 by Alisson Sol.

PowerShell module that extracts newly appeared text from sequential screen captures using pixel-level diffing and the operating system's built-in OCR engine.

## How it works

1. Compares two screenshots (current vs. previous) pixel-by-pixel to find changed regions
2. Crops the current image to the bounding box of changed rows
3. Runs OCR on the cropped delta image to extract only the new text

Pixel processing uses C# compiled at module load (no System.Drawing, ImageMagick, or Tesseract dependencies). OCR uses Windows.Media.Ocr (WinRT, the same engine as Snipping Tool) on Windows and the Apple Vision framework (via `swift`) on macOS. Linux is not supported.

When no previous screenshot is provided, the entire current image is treated as new content.

## Requirements

- PowerShell 7+ (.NET 10+)
- Windows (WinRT OCR) or macOS (Apple Vision, requires the `swift` toolchain)

## Usage

```powershell
Import-Module .\Get-NewText

# Extract new text by comparing two consecutive screenshots
Get-NewTextContent -CurrentScreenPath '.\screenshots\0002.png' -PreviousScreenPath '.\screenshots\0001.png'

# Treat entire image as new (no previous frame)
Get-NewTextContent -CurrentScreenPath '.\screenshots\0001.png'
```

## Testing

```powershell
.\Test-NewText.ps1
```

Compares screenshot `0008.png` (current) against `0007.png` (previous) and prints the OCR result. Debug artifacts (processed images, OCR output) are saved to `$env:TEMP\NewText\`.

## Structure

- `Get-NewText/` - PowerShell module (`.psm1` + `.psd1`) with embedded C# for fast pixel processing
- `Test-NewText.ps1` - Test script demonstrating module usage
- `screenshots/` - Sample sequential screen captures
