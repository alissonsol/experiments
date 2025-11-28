import { DEFAULT_RISK_CONFIG, PageAnalysis } from './types';

/**
 * Gets risk level text and color based on score
 */
function getRiskLevel(riskScore: number): { level: string; color: string } {
  const config = DEFAULT_RISK_CONFIG;
  
  if (riskScore <= config.RiskLowLimit) {
    return { level: 'Low Risk', color: config.LowRiskColor };
  } else if (riskScore <= config.RiskMediumLimit) {
    return { level: 'Medium Risk', color: config.MediumRiskColor };
  } else {
    return { level: 'High Risk', color: config.HighRiskColor };
  }
}

/**
 * Renders the page analysis in the popup
 */
function renderAnalysis(analysis: PageAnalysis): void {
  const container = document.getElementById('analysis-container');
  if (!container) return;

  const { level, color } = getRiskLevel(analysis.RiskScore);

  container.innerHTML = `
    <div class="risk-header" style="background-color: ${color}">
      <div class="risk-score">${analysis.RiskScore}</div>
      <div class="risk-level">${level}</div>
    </div>
    
    <div class="section">
      <h3>Classification</h3>
      <p>${escapeHtml(analysis.Classification)}</p>
    </div>
    
    <div class="section">
      <h3>Summary</h3>
      <p>${escapeHtml(analysis.Summary)}</p>
    </div>
    
    <div class="section">
      <h3>Risk Information</h3>
      <p>${escapeHtml(analysis.RiskInfo)}</p>
    </div>
    
    <div class="section">
      <h3>Moral Dimensions</h3>
      <ul class="morals-list">
        ${analysis.Morals.map(moral => `<li><strong>${escapeHtml(moral.Name)}:</strong> ${moral.Score} ${moral.Reply ? ` - ${escapeHtml(moral.Reply)}` : ''}</li>`).join('')}
      </ul>
    </div>
  `;
}

/**
 * Renders loading state
 */
function renderLoading(): void {
  const container = document.getElementById('analysis-container');
  if (!container) return;

  container.innerHTML = `
    <div class="loading">
      <div class="spinner"></div>
      <p>Analyzing page...</p>
    </div>
  `;
}

/**
 * Renders error or no analysis state
 */
function renderNoAnalysis(): void {
  const container = document.getElementById('analysis-container');
  if (!container) return;

  container.innerHTML = `
    <div class="no-analysis">
      <p>No analysis available for this page.</p>
      <p class="hint">Try refreshing the page.</p>
    </div>
  `;
}

/**
 * Escapes HTML to prevent XSS
 */
function escapeHtml(text: string): string {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

/**
 * Initialize popup
 */
async function init(): Promise<void> {
  renderLoading();

  // Request analysis from background script
  chrome.runtime.sendMessage({ type: 'GET_ANALYSIS' }, (response) => {
    if (chrome.runtime.lastError) {
      console.error('Error getting analysis:', chrome.runtime.lastError);
      renderNoAnalysis();
      return;
    }

    if (response?.data) {
      renderAnalysis(response.data);
    } else {
      renderNoAnalysis();
    }
  });
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', init);

