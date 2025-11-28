/**
 * Model Manager
 * 
 * Handles model lifecycle: initialization, caching, and provider management.
 * The model is downloaded once per device and cached using chrome.storage.local
 * and the Cache API, persisting across extension updates.
 * 
 * To change the model:
 * 1. Create a new ModelProvider implementation
 * 2. Update DEFAULT_PROVIDER_ID and MODEL_CONFIGS below
 * 3. Import and instantiate your provider in getProvider()
 * 
 * @module models/model-manager
 */

import { GemmaProvider } from './gemma-provider';
import {
    ModelConfig,
    ModelProgress,
    ModelProvider,
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

// ============================================================================
// PROVIDER MANAGEMENT
// ============================================================================

/** Singleton provider instance */
let providerInstance: ModelProvider | null = null;

/** Current initialization state */
let initializationPromise: Promise<void> | null = null;

/**
 * Get or create the model provider instance
 * 
 * To add a new provider:
 * 1. Import your provider class
 * 2. Add a case for your provider ID
 */
function getProvider(): ModelProvider {
  if (!providerInstance) {
    const config = MODEL_CONFIGS[DEFAULT_PROVIDER_ID];
    
    switch (DEFAULT_PROVIDER_ID) {
      case 'embedding-gemma':
        providerInstance = new GemmaProvider(config);
        break;
      // Add cases for new providers:
      // case 'my-new-model':
      //   providerInstance = new MyNewModelProvider(config);
      //   break;
      default:
        throw new Error(`Unknown model provider: ${DEFAULT_PROVIDER_ID}`);
    }
  }
  return providerInstance;
}

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

  const provider = getProvider();

  // Already initialized?
  if (provider.isReady()) {
    onProgress?.({ state: 'ready' });
    return;
  }

  // Start initialization
  initializationPromise = provider.initialize(onProgress)
    .catch((error) => {
      initializationPromise = null; // Allow retry on failure
      throw error;
    });

  return initializationPromise;
}

/**
 * Get the current model state
 */
export function getModelState(): ModelState {
  if (!providerInstance) {
    return 'uninitialized';
  }
  return providerInstance.getState();
}

/**
 * Check if the model is ready for execution
 */
export function isModelReady(): boolean {
  return providerInstance?.isReady() ?? false;
}

/**
 * Get platform capabilities
 */
export async function getPlatformCapabilities(): Promise<PlatformCapabilities> {
  return checkCapabilities();
}

/**
 * Get the active model provider
 * Returns null if model is not supported or not initialized
 */
export function getActiveProvider(): ModelProvider | null {
  return providerInstance;
}

/**
 * Unload the model and free resources
 */
export async function unloadModel(): Promise<void> {
  if (providerInstance) {
    await providerInstance.unload();
    providerInstance = null;
    initializationPromise = null;
  }
}

