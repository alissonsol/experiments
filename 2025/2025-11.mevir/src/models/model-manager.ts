/**
 * Model Manager
 *
 * Handles model lifecycle using Chrome's Offscreen Documents API.
 *
 * Chrome extension service workers don't have DOM access, which is required
 * by ONNX Runtime (used by Transformers.js). This manager creates an offscreen
 * document that has DOM access and communicates with it via messaging.
 *
 * The model is downloaded once per device and cached using the browser's
 * Cache API, persisting across extension updates.
 *
 * To change the model:
 * 1. Update the MODEL_ID in offscreen.ts
 * 2. Update MODEL_CONFIGS below if needed
 *
 * @module models/model-manager
 */

import {
  ModelConfig,
  ModelProgress,
  ModelState,
  PlatformCapabilities,
  PlatformType
} from './types';

// ============================================================================
// MODEL CONFIGURATION
// Change these values to switch to a different model
// ============================================================================

/**
 * Default model provider ID
 * Change this to switch the active model
 */
const DEFAULT_PROVIDER_ID = 'embedding-gemma';

/**
 * Model configurations
 * Add new model configs here when implementing new providers
 */
const MODEL_CONFIGS: Record<string, ModelConfig> = {
  'embedding-gemma': {
    id: 'embedding-gemma',
    modelPath: 'google/embedding-gemma',
    minRamMB: 200, // ~200MB with quantization
    requiresWebGPU: false, // Can run with WASM fallback
    supportedPlatforms: ['windows', 'macos', 'linux', 'chromeos']
  }
  // Add more model configurations here:
  // 'another-model': { ... }
};

// ============================================================================
// OFFSCREEN DOCUMENT MANAGEMENT
// ============================================================================

const OFFSCREEN_DOCUMENT_PATH = 'offscreen.html';

/** Track if offscreen document is being created */
let creatingOffscreen: Promise<void> | null = null;

// ============================================================================
// PLATFORM DETECTION
// ============================================================================

/**
 * Detect the current platform
 */
function detectPlatform(): PlatformType {
  const userAgent = navigator.userAgent.toLowerCase();
  const platform = navigator.platform?.toLowerCase() || '';

  if (userAgent.includes('android')) return 'android';
  if (userAgent.includes('iphone') || userAgent.includes('ipad')) return 'ios';
  if (userAgent.includes('cros')) return 'chromeos';
  if (platform.includes('win') || userAgent.includes('windows')) return 'windows';
  if (platform.includes('mac') || userAgent.includes('macintosh')) return 'macos';
  if (platform.includes('linux') || userAgent.includes('linux')) return 'linux';
  
  return 'unknown';
}

/**
 * Check platform capabilities for model execution
 */
async function checkCapabilities(): Promise<PlatformCapabilities> {
  const platform = detectPlatform();
  
  // Check WebGPU support
  let hasWebGPU = false;
  try {
    if ('gpu' in navigator) {
      const gpu = await (navigator as any).gpu?.requestAdapter();
      hasWebGPU = !!gpu;
    }
  } catch {
    hasWebGPU = false;
  }

  // Check WebAssembly support
  const hasWasm = typeof WebAssembly !== 'undefined';

  // Determine if model can run
  const config = MODEL_CONFIGS[DEFAULT_PROVIDER_ID];
  let canRunModel = hasWasm; // Minimum requirement
  let unsupportedReason: string | undefined;

  if (!hasWasm) {
    canRunModel = false;
    unsupportedReason = 'WebAssembly is not supported in this environment';
  } else if (config?.requiresWebGPU && !hasWebGPU) {
    canRunModel = false;
    unsupportedReason = 'This model requires WebGPU which is not available';
  } else if (config?.supportedPlatforms && 
             !config.supportedPlatforms.includes(platform) && 
             platform !== 'unknown') {
    // Allow 'unknown' platforms to try (fail gracefully at runtime)
    canRunModel = false;
    unsupportedReason = `This model does not support ${platform} platform`;
  }

  // Mobile platforms have limited support
  if (platform === 'android' || platform === 'ios') {
    canRunModel = false;
    unsupportedReason = 'Mobile platforms are not yet supported for local model execution';
  }

  return {
    platform,
    hasWebGPU,
    hasWasm,
    canRunModel,
    unsupportedReason
  };
}

/**
 * Ensure the offscreen document exists.
 * Creates it if it doesn't exist.
 */
async function ensureOffscreenDocument(): Promise<void> {
  // Check if offscreen document already exists
  const offscreenUrl = chrome.runtime.getURL(OFFSCREEN_DOCUMENT_PATH);

  // Use runtime.getContexts if available (Chrome 116+)
  if ('getContexts' in chrome.runtime) {
    const existingContexts = await (chrome.runtime as any).getContexts({
      contextTypes: ['OFFSCREEN_DOCUMENT'],
      documentUrls: [offscreenUrl]
    });

    if (existingContexts.length > 0) {
      console.log('[ModelManager] Offscreen document already exists');
      return; // Already exists
    }
  }

  // Create offscreen document if not already creating
  if (creatingOffscreen) {
    console.log('[ModelManager] Waiting for offscreen document creation...');
    await creatingOffscreen;
    return;
  }

  try {
    console.log('[ModelManager] Creating offscreen document...');
    creatingOffscreen = chrome.offscreen.createDocument({
      url: OFFSCREEN_DOCUMENT_PATH,
      reasons: [chrome.offscreen.Reason.WORKERS],
      justification: 'Run Transformers.js ML model for content analysis'
    });

    await creatingOffscreen;
    console.log('[ModelManager] Offscreen document created successfully');
  } catch (error) {
    // If creation fails due to already existing, that's OK
    if (error instanceof Error && error.message.includes('single offscreen')) {
      console.log('[ModelManager] Offscreen document already exists (from error)');
    } else {
      throw error;
    }
  } finally {
    creatingOffscreen = null;
  }
}

/** Track if we've waited for offscreen to be ready */
let offscreenReady = false;

/**
 * Send a message to the offscreen document and wait for response
 */
async function sendToOffscreen<T>(
  type: string,
  data?: Record<string, unknown>
): Promise<T> {
  await ensureOffscreenDocument();

  // Small delay on first message to ensure offscreen document is fully loaded
  if (!offscreenReady) {
    await new Promise(resolve => setTimeout(resolve, 100));
    offscreenReady = true;
  }

  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(
      { type, target: 'offscreen', data },
      (response) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
        } else {
          resolve(response as T);
        }
      }
    );
  });
}

// ============================================================================
// STATE MANAGEMENT
// ============================================================================

/** Current model state (cached from offscreen document) */
let currentState: ModelState = 'uninitialized';

/** Current initialization promise */
let initializationPromise: Promise<void> | null = null;

// ============================================================================
// PUBLIC API
// ============================================================================

/**
 * Initialize the model manager and download the model if needed.
 * Safe to call multiple times - will only initialize once.
 *
 * @param onProgress - Optional callback for progress updates
 * @returns Promise that resolves when ready, or rejects with error
 */
export async function initializeModel(
  onProgress?: (progress: ModelProgress) => void
): Promise<void> {
  // Check platform support first
  const capabilities = await checkCapabilities();

  if (!capabilities.canRunModel) {
    const error: ModelProgress = {
      state: 'unsupported',
      errorMessage: capabilities.unsupportedReason || 'Platform not supported'
    };
    onProgress?.(error);
    console.warn('[ModelManager] Model not supported:', capabilities.unsupportedReason);
    return; // Fail safely - don't throw, just return
  }

  // Return existing initialization if in progress
  if (initializationPromise) {
    return initializationPromise;
  }

  // Already initialized?
  if (currentState === 'ready') {
    onProgress?.({ state: 'ready' });
    return;
  }

  // Start initialization via offscreen document
  onProgress?.({ state: 'downloading', downloadProgress: 0, currentFile: 'Creating offscreen document...' });

  initializationPromise = (async () => {
    try {
      const result = await sendToOffscreen<{ success: boolean; error?: string }>(
        'OFFSCREEN_INIT_MODEL'
      );

      if (result.success) {
        currentState = 'ready';
        onProgress?.({ state: 'ready', downloadProgress: 100 });
        console.log('[ModelManager] Model initialized successfully via offscreen document');
      } else {
        currentState = 'error';
        onProgress?.({ state: 'error', errorMessage: result.error || 'Unknown error' });
        throw new Error(result.error || 'Model initialization failed');
      }
    } catch (error) {
      currentState = 'error';
      initializationPromise = null; // Allow retry on failure
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      onProgress?.({ state: 'error', errorMessage });
      throw error;
    }
  })();

  return initializationPromise;
}

/**
 * Get the current model state
 */
export function getModelState(): ModelState {
  return currentState;
}

/**
 * Check if the model is ready for execution
 */
export function isModelReady(): boolean {
  return currentState === 'ready';
}

/**
 * Get platform capabilities
 */
export async function getPlatformCapabilities(): Promise<PlatformCapabilities> {
  return checkCapabilities();
}

/**
 * Execute a prompt using the model via the offscreen document
 */
export async function executePromptViaOffscreen(prompt: string): Promise<{
  success: boolean;
  response?: string;
  error?: string;
  executionTimeMs?: number;
}> {
  if (currentState !== 'ready') {
    return { success: false, error: 'Model is not initialized' };
  }

  return sendToOffscreen('OFFSCREEN_EXECUTE_PROMPT', { prompt });
}

/**
 * Unload the model and free resources
 */
export async function unloadModel(): Promise<void> {
  if (currentState !== 'uninitialized') {
    await sendToOffscreen('OFFSCREEN_UNLOAD');
    currentState = 'uninitialized';
    initializationPromise = null;
  }
}

