/**
 * Offscreen Document Script for ML Model Execution
 * 
 * This script runs in an offscreen document, which has DOM access unlike
 * the service worker. It handles all Transformers.js model operations.
 * 
 * Communication with the service worker is done via chrome.runtime messaging.
 * 
 * Message Types:
 * - OFFSCREEN_INIT_MODEL: Initialize/download the model
 * - OFFSCREEN_EXECUTE_PROMPT: Run inference on a prompt
 * - OFFSCREEN_GET_STATE: Get current model state
 * - OFFSCREEN_UNLOAD: Unload the model
 * 
 * @module offscreen
 */

import { env, pipeline } from '@xenova/transformers';

// ============================================================================
// MODEL CONFIGURATION
// Change these values to use a different model
// ============================================================================

/**
 * HuggingFace model ID
 * Change this to use a different model from HuggingFace
 */
const MODEL_ID = 'Xenova/all-MiniLM-L6-v2';

/**
 * Whether to use quantized model weights
 */
const USE_QUANTIZED = true;

// ============================================================================
// MODEL STATE
// ============================================================================

type ModelState = 'uninitialized' | 'downloading' | 'loading' | 'ready' | 'error';

// Use 'any' for the pipeline since the exact type varies by pipeline type
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let modelPipeline: any = null;
let modelState: ModelState = 'uninitialized';
let initError: string | null = null;

// ============================================================================
// MODEL OPERATIONS
// ============================================================================

/**
 * Configure the environment for Chrome extension
 * Must be called before any model operations
 */
function configureEnvironment(): void {
  // Configure Transformers.js for Chrome extension environment
  env.allowLocalModels = false;
  env.useBrowserCache = true;

  // Set WASM paths to point to the bundled WASM files in the extension
  // The WASM files are copied to the dist folder by webpack
  // We use chrome.runtime.getURL to get the correct extension URL
  const wasmPath = chrome.runtime.getURL('/');

  // Configure ONNX Runtime WASM backend paths
  if (env.backends?.onnx?.wasm) {
    env.backends.onnx.wasm.wasmPaths = wasmPath;

    // CRITICAL: Disable multi-threading to avoid web worker blob URL issues
    // Chrome extensions block blob URLs in workers due to CSP restrictions
    // Setting numThreads to 1 forces single-threaded execution
    env.backends.onnx.wasm.numThreads = 1;
  }

  console.log('[Offscreen] Environment configured, WASM path:', wasmPath, 'numThreads: 1');
}

/**
 * Initialize the model
 */
async function initializeModel(): Promise<{ success: boolean; error?: string }> {
  if (modelState === 'ready' && modelPipeline) {
    return { success: true };
  }

  // Prevent multiple simultaneous initialization attempts
  if (modelState === 'downloading' || modelState === 'loading') {
    console.log('[Offscreen] Model initialization already in progress');
    // Wait for existing initialization to complete
    return new Promise((resolve) => {
      const checkState = setInterval(() => {
        if (modelState === 'ready') {
          clearInterval(checkState);
          resolve({ success: true });
        } else if (modelState === 'error') {
          clearInterval(checkState);
          resolve({ success: false, error: initError || 'Unknown error' });
        }
      }, 100);
    });
  }

  try {
    modelState = 'downloading';
    console.log('[Offscreen] Initializing model...');

    // Configure environment before loading model
    configureEnvironment();

    modelState = 'loading';
    console.log('[Offscreen] Loading model:', MODEL_ID);

    // Create the feature extraction pipeline
    modelPipeline = await pipeline('feature-extraction', MODEL_ID, {
      quantized: USE_QUANTIZED,
      progress_callback: (progress: { status: string; progress?: number; file?: string }) => {
        if (progress.status === 'downloading') {
          console.log(`[Offscreen] Downloading: ${progress.file} - ${Math.round(progress.progress || 0)}%`);
        } else if (progress.status === 'progress') {
          console.log(`[Offscreen] Loading: ${progress.file} - ${Math.round(progress.progress || 0)}%`);
        }
      }
    });

    modelState = 'ready';
    initError = null;
    console.log('[Offscreen] Model initialized successfully');
    return { success: true };

  } catch (error) {
    modelState = 'error';
    initError = error instanceof Error ? error.message : 'Unknown error';
    console.error('[Offscreen] Model initialization failed:', error);
    return { success: false, error: initError };
  }
}

/**
 * Execute a prompt using the model
 */
async function executePrompt(prompt: string): Promise<{
  success: boolean;
  response?: string;
  error?: string;
  executionTimeMs?: number;
}> {
  const startTime = Date.now();

  if (modelState !== 'ready' || !modelPipeline) {
    return { success: false, error: 'Model is not initialized' };
  }

  try {
    // Run the embedding model
    const output = await modelPipeline(prompt, {
      pooling: 'mean',
      normalize: true
    });

    // Convert embeddings to array
    const embeddings = Array.from(output.data as Float32Array);

    const response = JSON.stringify({
      embeddings: embeddings.slice(0, 10),
      dimensions: output.dims,
      model: MODEL_ID
    });

    return {
      success: true,
      response,
      executionTimeMs: Date.now() - startTime
    };

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    console.error('[Offscreen] Execution error:', error);
    return {
      success: false,
      error: errorMessage,
      executionTimeMs: Date.now() - startTime
    };
  }
}

/**
 * Get current model state
 */
function getState(): { state: ModelState; error: string | null } {
  return { state: modelState, error: initError };
}

/**
 * Unload the model
 */
async function unloadModel(): Promise<void> {
  modelPipeline = null;
  modelState = 'uninitialized';
  initError = null;
  console.log('[Offscreen] Model unloaded');
}

// ============================================================================
// MESSAGE HANDLING
// ============================================================================

/**
 * Message types for communication with service worker
 */
interface OffscreenMessage {
  type: 'OFFSCREEN_INIT_MODEL' | 'OFFSCREEN_EXECUTE_PROMPT' | 'OFFSCREEN_GET_STATE' | 'OFFSCREEN_UNLOAD';
  target: 'offscreen';
  data?: {
    prompt?: string;
  };
}

/**
 * Handle messages from the service worker
 */
chrome.runtime.onMessage.addListener((
  message: OffscreenMessage,
  _sender: chrome.runtime.MessageSender,
  sendResponse: (response: unknown) => void
) => {
  // Only handle messages targeted at the offscreen document
  if (message.target !== 'offscreen') {
    return false;
  }

  console.log('[Offscreen] Received message:', message.type);

  switch (message.type) {
    case 'OFFSCREEN_INIT_MODEL':
      initializeModel().then(sendResponse);
      return true; // Keep channel open for async response

    case 'OFFSCREEN_EXECUTE_PROMPT':
      if (!message.data?.prompt) {
        sendResponse({ success: false, error: 'No prompt provided' });
        return false;
      }
      executePrompt(message.data.prompt).then(sendResponse);
      return true;

    case 'OFFSCREEN_GET_STATE':
      sendResponse(getState());
      return false;

    case 'OFFSCREEN_UNLOAD':
      unloadModel().then(() => sendResponse({ success: true }));
      return true;

    default:
      return false;
  }
});

console.log('[Offscreen] Offscreen document loaded and ready');

