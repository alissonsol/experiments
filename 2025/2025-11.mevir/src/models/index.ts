/**
 * Model API Facade
 * 
 * This module provides the public API for interacting with language models.
 * The main export is ExecutePrompt, which provides a simple interface for
 * running prompts through the configured model.
 * 
 * Usage:
 *   import { ExecutePrompt, initializeModel } from './models';
 *   
 *   // Initialize on extension install
 *   await initializeModel();
 *   
 *   // Execute prompts
 *   const result = await ExecutePrompt({ prompt: 'Hello, world!' });
 * 
 * @module models
 */

// Re-export types for consumers
export {
    ExecutePromptParams,
    ExecutePromptResult, ModelProgress, ModelState, PlatformCapabilities,
    PlatformType
} from './types';

// Re-export manager functions
export {
    executePromptViaOffscreen, getModelState, getPlatformCapabilities, initializeModel, isModelReady, unloadModel
} from './model-manager';

import {
    executePromptViaOffscreen,
    initializeModel,
    isModelReady
} from './model-manager';
import {
    ExecutePromptParams,
    ExecutePromptResult
} from './types';

/**
 * Execute a prompt using the configured language model.
 *
 * This is the main API for interacting with the model. It handles:
 * - Checking if the model is ready
 * - Auto-initializing if needed (optional)
 * - Executing the prompt via the offscreen document
 * - Returning structured results
 *
 * The model runs in an offscreen document to work around Chrome extension
 * service worker limitations (no DOM access required by ONNX Runtime).
 *
 * The model must be initialized before calling this function.
 * Call initializeModel() during extension installation.
 *
 * @param params - The prompt parameters
 * @param autoInit - If true, automatically initialize the model if not ready (default: false)
 * @returns Promise with the execution result
 *
 * @example
 * ```typescript
 * // Basic usage
 * const result = await ExecutePrompt({ prompt: 'Analyze this text' });
 * if (result.success) {
 *   console.log(result.response);
 * }
 *
 * // With options
 * const result = await ExecutePrompt({
 *   prompt: 'Generate response',
 *   maxTokens: 100,
 *   temperature: 0.7
 * });
 * ```
 */
export async function ExecutePrompt(
  params: ExecutePromptParams,
  autoInit: boolean = false
): Promise<ExecutePromptResult> {
  // Check if model is ready
  if (!isModelReady()) {
    if (autoInit) {
      try {
        await initializeModel();
      } catch (error) {
        return {
          success: false,
          error: `Failed to auto-initialize model: ${error instanceof Error ? error.message : 'Unknown error'}`
        };
      }
    } else {
      return {
        success: false,
        error: 'Model is not initialized. Call initializeModel() first or set autoInit=true.'
      };
    }
  }

  // Execute the prompt via the offscreen document
  return executePromptViaOffscreen(params.prompt);
}

/**
 * Check if the current platform supports the model
 * This is a convenience function that combines capability checking
 * 
 * @returns Promise<boolean> - true if model can run on this platform
 */
export async function canRunModel(): Promise<boolean> {
  const { getPlatformCapabilities } = await import('./model-manager');
  const capabilities = await getPlatformCapabilities();
  return capabilities.canRunModel;
}

