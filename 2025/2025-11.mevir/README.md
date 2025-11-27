# MEVIR - Chrome Extension for Page Analysis

A Chrome extension written in TypeScript that analyzes web page content and provides risk scoring.

## Features

- **Page Content Extraction**: Extracts text content from web pages, including divs and iframes
- **Link Analysis**: Collects all links with their URI schemes
- **Risk Scoring**: Displays a color-coded risk score (0-100) in the browser toolbar
  - 🟢 Green (0-33): Low Risk
  - 🟡 Yellow (34-66): Medium Risk
  - 🔴 Red (67-100): High Risk
- **Analysis Popup**: Click the extension icon to view detailed analysis including:
  - Classification
  - Summary
  - Moral dimensions analysis
  - Risk information
- **Mobile-Compatible UI**: Responsive design that works on various screen sizes

## Project Structure

```
mevir/
├── src/
│   ├── types.ts          # TypeScript interfaces
│   ├── content.ts        # Content script (page analysis)
│   ├── background.ts     # Background service worker
│   ├── popup.ts          # Popup UI logic
│   └── api.ts            # DoAnalysis API (local mock)
├── popup.html            # Popup HTML
├── popup.css             # Popup styles
├── manifest.json         # Chrome extension manifest (v3)
├── icons/                # Extension icons
├── .vscode/              # VS Code configuration
├── package.json          # Dependencies
├── tsconfig.json         # TypeScript configuration
└── webpack.config.js     # Build configuration
```

## Prerequisites

- [Node.js](https://nodejs.org/) (v16 or higher)
- [Visual Studio Code](https://code.visualstudio.com/)
- [Google Chrome](https://www.google.com/chrome/) browser

## Installation & Build

### Using VS Code Tasks (Recommended)

1. **Open the project in VS Code**:
   ```bash
   code mevir
   ```

2. **Install dependencies and build**:
   - Press `Ctrl+Shift+B` (or `Cmd+Shift+B` on Mac)
   - Select "Build" task
   - This will automatically install dependencies and build the project

### Using Command Line

1. **Navigate to project directory**:
   ```bash
   cd mevir
   ```

2. **Install dependencies**:
   ```bash
   npm install
   ```

3. **Build the project**:
   ```bash
   npm run build
   ```

4. **For development (watch mode)**:
   ```bash
   npm run watch
   ```

## Creating Extension Icons

Before loading the extension, you need to create PNG icons:

1. **Run the icon generator script**:
   ```bash
   node scripts/generate-icons.js
   ```

2. **Convert SVG to PNG** using one of these methods:
   - Use an online converter (svgtopng.com)
   - Use ImageMagick: `convert -background none icons/icon128.svg icons/icon128.png`
   - Use Inkscape: `inkscape -w 128 -h 128 icons/icon128.svg -o icons/icon128.png`

3. **Create icons for all sizes**: 16x16, 48x48, 128x128 pixels

## Installing in Chrome

1. **Build the project** (see above)

2. **Open Chrome Extensions page**:
   - Navigate to `chrome://extensions/`
   - Or: Menu → More Tools → Extensions

3. **Enable Developer Mode**:
   - Toggle "Developer mode" switch in the top-right corner

4. **Load the extension**:
   - Click "Load unpacked"
   - Select the `dist` folder in your project directory

5. **Pin the extension** (optional):
   - Click the puzzle icon in Chrome toolbar
   - Click the pin icon next to "MEVIR"

## Running and Debugging

### Using VS Code Debugger

1. **Press `F5`** or go to Run → Start Debugging
2. **Select "Launch Chrome with Extension"**
3. Chrome will open with the extension loaded and DevTools open

### Manual Testing

1. **Open any website** in Chrome after loading the extension
2. **Check the badge**: The extension icon should show a number (risk score)
3. **Click the icon**: A popup will appear showing the page analysis
4. **Test different pages**: Navigate to different websites to see varying analyses

### Debugging Tips

- **Background Script**: Right-click the extension icon → "Inspect popup" → Go to "Service Worker" in the Extensions page
- **Content Script**: Open Chrome DevTools (F12) on any page → Console tab
- **Popup**: Right-click the extension icon → "Inspect popup"
- **Source Maps**: Available in DevTools for debugging TypeScript directly

## Development

### Watch Mode

For active development, use watch mode to auto-rebuild on changes:

```bash
npm run watch
```

After making changes:
1. The build will update automatically
2. Go to `chrome://extensions/`
3. Click the refresh icon on the MEVIR extension card
4. Reload the web page you're testing

### Project Commands

| Command | Description |
|---------|-------------|
| `npm install` | Install dependencies |
| `npm run build` | Production build |
| `npm run watch` | Development build with file watching |
| `npm run clean` | Clean the dist folder |

## API Extension

The `DoAnalysis` function in `src/api.ts` currently returns default values. To connect to a real API:

1. Edit `src/api.ts`
2. Replace the mock implementation with actual API calls
3. Update the return type if needed

Example:
```typescript
export async function DoAnalysis(pageContent: PageContent): Promise<PageAnalysis> {
  const response = await fetch('https://your-api.com/analyze', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(pageContent)
  });
  return response.json();
}
```

## Configuration

Risk thresholds and colors can be modified in `src/types.ts`:

```typescript
export const DEFAULT_RISK_CONFIG: RiskConfig = {
  RiskLowLimit: 33,      // Scores 0-33 = Low Risk
  RiskMediumLimit: 66,   // Scores 34-66 = Medium Risk
  LowRiskColor: '#22c55e',    // Green
  MediumRiskColor: '#eab308', // Yellow
  HighRiskColor: '#ef4444'    // Red
};
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Extension not loading | Ensure `dist` folder exists and contains built files |
| Badge not showing | Refresh the page; check console for errors |
| Popup blank | Check if background service worker is running |
| Build errors | Run `npm install` to ensure dependencies are installed |

## License

MIT License

