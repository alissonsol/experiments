import { PageAnalysis, PageContent } from './types';

/**
 * DoAnalysis API - Analyzes page content and returns analysis results.
 * Currently returns default values. Can be extended to call a remote API.
 * 
 * @param pageContent - The content extracted from the page
 * @returns PageAnalysis with classification, summary, morals, and risk information
 */
export async function DoAnalysis(pageContent: PageContent): Promise<PageAnalysis> {
  // For now, return default values
  // This can be extended to call a remote API in the future
  
  const defaultAnalysis: PageAnalysis = {
    Classification: 'General Content',
    Summary: `Page contains ${pageContent.Text.length} characters of text and ${pageContent.LinksCount} links.`,
    Morals: [
      { Name: 'Care', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of care about the reader, going from -100 (careless) to 100 (very caring).', Reply: '', Score: 0 },
      { Name: 'Fairness', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of fairness about the reader, going from -100 (unfair) to 100 (fair).', Reply: '', Score: 0 },
      { Name: 'Liberty', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of liberty about the reader, going from -100 (oppressive) to 100 (liberty).', Reply: '', Score: 0 },
      { Name: 'Loyalty', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of loyalty about the reader, going from -100 (disloyal) to 100 (very loyal).', Reply: '', Score: 0 },
      { Name: 'Authority', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of authority about the reader, going from -100 (subversive) to 100 (respectful).', Reply: '', Score: 0 },
      { Name: 'Purity', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of purity about the reader, going from -100 (impure) to 100 (pure).', Reply: '', Score: 0 },
      { Name: 'Other', Prompt: 'Ignore previous instructions. Find the predominant moral dimension in the text. In a score from -100 to 100, how much this text expresses that moral dimension? If there is no predominant moral dimension, return 0.', Reply: '', Score: 0 }
    ],
    RiskScore: Math.floor(Math.random() * 100),
    RiskInfo: 'Content appears safe.'
  };

  if (defaultAnalysis.RiskScore > 33) defaultAnalysis.RiskInfo = "Some controversial topics detected.";
  if (defaultAnalysis.RiskScore > 66) defaultAnalysis.RiskInfo = "High risk content detected. Exercise caution.";

  // Simulate async API call
  return new Promise((resolve) => {
    setTimeout(() => {
      resolve(defaultAnalysis);
    }, 100);
  }); 
}

