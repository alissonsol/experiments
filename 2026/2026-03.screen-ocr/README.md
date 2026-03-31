# screen-ocr

PowerShell module that extracts newly appeared text from sequential screen captures using pixel-level diffing and Tesseract OCR.

## How it works

1. Compares two screenshots (current vs. previous) pixel-by-pixel using compiled C# for performance
2. Replaces unchanged pixels with a white background, preserving full rows that contain any change
3. Crops the result to the bounding box of changed rows
4. Runs Tesseract OCR on the cropped delta image to extract only the new text

When no previous screenshot is provided, the entire current image is treated as new content.

## Requirements

- PowerShell 7+
- [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) installed and available in PATH
- On macOS: `brew install mono-libgdiplus` (for System.Drawing support)

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

Compares screenshot `0003.png` (current) against `0002.png` (previous) and prints the OCR result. Debug artifacts (processed images, OCR output) are saved to `$env:TEMP\NewText\`.

## Structure

- `Get-NewText/` - PowerShell module (`.psm1` + `.psd1`) with embedded C# for fast pixel processing
- `Test-NewText.ps1` - Test script demonstrating module usage
- `screenshots/` - Sample sequential screen captures
