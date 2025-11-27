/**
 * Information about a link found in the page
 */
export interface LinkInfo {
  /** URL of the link */
  LinkUrl: string;
  /** URI Scheme extracted from the URL (e.g., "http", "https", "mailto") */
  LinkType: string;
}

/**
 * Content extracted from a web page
 */
export interface PageContent {
  /** Plain text content from the page (max 1MB) */
  Text: string;
  /** Whether the text was truncated at the 1MB limit */
  IsTextCut: boolean;
  /** Total number of links in the page */
  LinksCount: number;
  /** Array of link information */
  Links: LinkInfo[];
}

/**
 * Analysis result for a page
 */
export interface PageAnalysis {
  /** Classification of the page content */
  Classification: string;
  /** Summary of the page content */
  Summary: string;
  /** Moral dimensions analysis: Care, Fairness, Liberty, Loyalty, Authority, Purity, Other */
  Morals: string[];
  /** Risk score from 0 to 100 */
  RiskScore: number;
  /** Information about the page risk */
  RiskInfo: string;
}

/**
 * Risk configuration settings
 */
export interface RiskConfig {
  /** Upper limit for low risk (default: 33) */
  RiskLowLimit: number;
  /** Upper limit for medium risk (default: 66) */
  RiskMediumLimit: number;
  /** Color for low risk (default: green) */
  LowRiskColor: string;
  /** Color for medium risk (default: yellow) */
  MediumRiskColor: string;
  /** Color for high risk (default: red) */
  HighRiskColor: string;
}

/**
 * Default risk configuration
 */
export const DEFAULT_RISK_CONFIG: RiskConfig = {
  RiskLowLimit: 33,
  RiskMediumLimit: 66,
  LowRiskColor: '#22c55e',      // Green
  MediumRiskColor: '#eab308',   // Yellow
  HighRiskColor: '#ef4444'      // Red
};

/**
 * Message types for communication between extension components
 */
export type MessageType = 
  | { type: 'PAGE_CONTENT'; data: PageContent }
  | { type: 'PAGE_ANALYSIS'; data: PageAnalysis }
  | { type: 'GET_ANALYSIS' }
  | { type: 'ANALYSIS_RESULT'; data: PageAnalysis | null };

