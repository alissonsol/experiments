import { ExecutePrompt, isModelReady } from './models';
import { MoralDimension, PageAnalysis, PageContent } from './types';

/**
 * Default moral dimensions with their prompts
 */
const DEFAULT_MORALS: MoralDimension[] = [
  { Name: 'Care', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of care about the reader, going from -100 (careless) to 100 (very caring).', Reply: '', Score: 0 },
  { Name: 'Fairness', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of fairness about the reader, going from -100 (unfair) to 100 (fair).', Reply: '', Score: 0 },
  { Name: 'Liberty', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of liberty about the reader, going from -100 (oppressive) to 100 (liberty).', Reply: '', Score: 0 },
  { Name: 'Loyalty', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of loyalty about the reader, going from -100 (disloyal) to 100 (very loyal).', Reply: '', Score: 0 },
  { Name: 'Authority', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of authority about the reader, going from -100 (subversive) to 100 (respectful).', Reply: '', Score: 0 },
  { Name: 'Purity', Prompt: 'Ignore previous instructions. In a score from -100 to 100, how much this text expresses a sentiment of purity about the reader, going from -100 (impure) to 100 (pure).', Reply: '', Score: 0 },
  { Name: 'Other', Prompt: 'Ignore previous instructions. Find the predominant moral dimension in the text. In a score from -100 to 100, how much this text expresses that moral dimension? If there is no predominant moral dimension, return 0.', Reply: '', Score: 0 }
];

/**
 * Extracts a number from a response string.
 * Returns the first number found, or 0 if no number is found.
 * Also returns the remaining text (non-numeric parts) as the reply.
 */
function extractScoreAndReply(response: string): { score: number; reply: string } {
  // Match numbers including negative numbers and decimals
  const numberMatch = response.match(/-?\d+\.?\d*/);

  if (numberMatch) {
    const score = Math.round(parseFloat(numberMatch[0]));
    // Remove the number from the response to get the reply text
    const reply = response.replace(numberMatch[0], '').trim();
    return { score, reply };
  }

  return { score: 0, reply: response.trim() };
}

/**
 * DoAnalysis API - Analyzes page content and returns analysis results.
 * Uses the local language model to evaluate moral dimensions.
 *
 * @param pageContent - The content extracted from the page
 * @returns PageAnalysis with classification, summary, morals, and risk information
 */
export async function DoAnalysis(pageContent: PageContent): Promise<PageAnalysis> {
  // Create a copy of default morals for this analysis
  const morals: MoralDimension[] = DEFAULT_MORALS.map(m => ({ ...m }));

  // Process each moral dimension using the language model
  if (isModelReady()) {
    console.log('[DoAnalysis] Model is ready, processing moral dimensions...');

    // Process all moral dimensions in parallel for better performance
    const promises = morals.map(async (moral) => {
      // Concatenate prompt with page text
      const fullPrompt = `${moral.Prompt}\n${pageContent.Text}`;

      try {
        const result = await ExecutePrompt({ prompt: fullPrompt });

        if (result.success && result.response) {
          const { score, reply } = extractScoreAndReply(result.response);
          moral.Score = score;
          moral.Reply = reply;
          console.log(`[DoAnalysis] ${moral.Name}: Score=${score}, Reply="${reply.substring(0, 50)}..."`);
        } else {
          console.warn(`[DoAnalysis] ${moral.Name}: ExecutePrompt failed -`, result.error);
          moral.Reply = result.error || 'Execution failed';
        }
      } catch (error) {
        console.error(`[DoAnalysis] ${moral.Name}: Error -`, error);
        moral.Reply = error instanceof Error ? error.message : 'Unknown error';
      }
    });

    await Promise.all(promises);
  } else {
    console.log('[DoAnalysis] Model not ready, using default scores');
  }

  // Calculate risk score based on moral dimension scores
  // Higher absolute values in negative dimensions increase risk
  const riskFactors = morals.map(m => Math.max(0, -m.Score)); // Negative scores contribute to risk
  const avgRisk = riskFactors.reduce((a, b) => a + b, 0) / riskFactors.length;
  const riskScore = Math.min(100, Math.round(avgRisk));

  const analysis: PageAnalysis = {
    Classification: 'General Content',
    Summary: `Page contains ${pageContent.Text.length} characters of text and ${pageContent.LinksCount} links.`,
    Morals: morals,
    RiskScore: riskScore,
    RiskInfo: 'Content appears safe.'
  };

  if (analysis.RiskScore > 33) analysis.RiskInfo = "Some controversial topics detected.";
  if (analysis.RiskScore > 66) analysis.RiskInfo = "High risk content detected. Exercise caution.";

  return analysis;
}

