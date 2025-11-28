import { DoAnalysis } from './api';
import {
  getModelState,
  getPlatformCapabilities,
  initializeModel,
  ModelProgress
} from './models';
import { DEFAULT_RISK_CONFIG, MessageType, PageAnalysis, PageContent } from './types';

// Store analysis results per tab
const tabAnalysis = new Map<number, PageAnalysis>();

// Track model initialization state
let modelInitialized = false;
let modelInitError: string | null = null;

/**
 * Initialize the language model on extension install/startup.
 * The model is downloaded once and cached for future use.
 */
async function initializeLanguageModel(): Promise<void> {
  console.log('[Background] Checking platform capabilities...');

  const capabilities = await getPlatformCapabilities();
  console.log('[Background] Platform capabilities:', capabilities);

  if (!capabilities.canRunModel) {
    console.warn('[Background] Model not supported on this platform:', capabilities.unsupportedReason);
    modelInitError = capabilities.unsupportedReason || 'Platform not supported';
    return;
  }

  console.log('[Background] Initializing language model...');

  try {
    await initializeModel((progress: ModelProgress) => {
      console.log('[Background] Model progress:', progress);

      if (progress.state === 'error') {
        modelInitError = progress.errorMessage || 'Unknown error';
      }
    });

    modelInitialized = true;
    console.log('[Background] Model initialized successfully. State:', getModelState());
  } catch (error) {
    modelInitError = error instanceof Error ? error.message : 'Unknown error';
    console.error('[Background] Failed to initialize model:', error);
    // Fail safely - the extension will continue to work without the model
  }
}

/**
 * Gets the appropriate color based on risk score
 */
function getRiskColor(riskScore: number): string {
  const config = DEFAULT_RISK_CONFIG;
  
  if (riskScore <= config.RiskLowLimit) {
    return config.LowRiskColor;
  } else if (riskScore <= config.RiskMediumLimit) {
    return config.MediumRiskColor;
  } else {
    return config.HighRiskColor;
  }
}

/**
 * Updates the extension badge with the risk score
 */
async function updateBadge(tabId: number, riskScore: number): Promise<void> {
  const color = getRiskColor(riskScore);
  
  await chrome.action.setBadgeText({
    tabId,
    text: riskScore.toString()
  });
  
  await chrome.action.setBadgeBackgroundColor({
    tabId,
    color
  });

  await chrome.action.setBadgeTextColor({
    tabId,
    color: '#ffffff'
  });
}

/**
 * Handles page content from content script
 */
async function handlePageContent(tabId: number, pageContent: PageContent): Promise<void> {
  try {
    // Call the DoAnalysis API
    const analysis = await DoAnalysis(pageContent);
    
    // Store the analysis for this tab
    tabAnalysis.set(tabId, analysis);
    
    // Update the badge with risk score
    await updateBadge(tabId, analysis.RiskScore);
  } catch (error) {
    console.error('Error analyzing page:', error);
  }
}

// Listen for messages from content script and popup
chrome.runtime.onMessage.addListener((message: MessageType, sender, sendResponse) => {
  if (message.type === 'PAGE_CONTENT' && sender.tab?.id) {
    handlePageContent(sender.tab.id, message.data);
  } else if (message.type === 'GET_ANALYSIS') {
    // Get current active tab's analysis
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const tabId = tabs[0]?.id;
      if (tabId) {
        const analysis = tabAnalysis.get(tabId) || null;
        sendResponse({ type: 'ANALYSIS_RESULT', data: analysis });
      } else {
        sendResponse({ type: 'ANALYSIS_RESULT', data: null });
      }
    });
    return true; // Keep channel open for async response
  } else if (message.type === 'GET_MODEL_STATUS') {
    // Return model initialization status
    sendResponse({
      type: 'MODEL_STATUS',
      data: {
        initialized: modelInitialized,
        state: getModelState(),
        error: modelInitError
      }
    });
    return false;
  }
});

// Clean up when tab is closed
chrome.tabs.onRemoved.addListener((tabId) => {
  tabAnalysis.delete(tabId);
});

// Re-analyze when tab is updated
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === 'complete') {
    // Clear previous analysis - content script will send new content
    tabAnalysis.delete(tabId);
  }
});

// ============================================================================
// EXTENSION LIFECYCLE
// ============================================================================

/**
 * Initialize model when extension is installed or updated.
 * The model is cached and will persist across extension updates.
 */
chrome.runtime.onInstalled.addListener((details) => {
  console.log('[Background] Extension installed/updated:', details.reason);

  // Initialize the language model
  // This downloads the model if not already cached
  initializeLanguageModel().catch((error) => {
    console.error('[Background] Model initialization failed:', error);
  });
});

/**
 * Initialize model when browser starts with extension already installed.
 * This ensures the model is ready when the user starts browsing.
 */
chrome.runtime.onStartup.addListener(() => {
  console.log('[Background] Browser startup detected');

  initializeLanguageModel().catch((error) => {
    console.error('[Background] Model initialization failed on browser startup:', error);
  });
});

/**
 * Initialize on service worker load.
 * This handles:
 * - Extension reload during development
 * - Service worker restart after being terminated
 * - First load after extension is enabled
 *
 * The initializeModel function is idempotent - safe to call multiple times.
 */
console.log('[Background] Service worker loaded, initializing model...');
initializeLanguageModel().catch((error) => {
  console.error('[Background] Model initialization failed on service worker load:', error);
});
