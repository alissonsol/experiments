import { PageContent, PageAnalysis, DEFAULT_RISK_CONFIG, MessageType } from './types';
import { DoAnalysis } from './api';

// Store analysis results per tab
const tabAnalysis = new Map<number, PageAnalysis>();

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

