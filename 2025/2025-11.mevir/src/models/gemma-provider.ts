/**
 * EmbeddingGemma Model Provider
 * 
 * Implements the ModelProvider interface for Google's EmbeddingGemma model.
 * Uses Transformers.js to run the model locally in the browser.
 * 
 * EmbeddingGemma is a 308M parameter embedding model optimized for on-device use.
 * It supports 100+ languages and can run with ~200MB RAM when quantized.
 * 
 * Model source: https://huggingface.co/google/embedding-gemma
 * 
 * To switch to a different model:
 * 1. Copy this file as a template
 * 2. Change MODEL_ID and QUANTIZED_MODEL_ID
 * 3. Adjust the pipeline type in initialize()
 * 4. Update executePrompt() for your model's output format
 * 
 * @module models/gemma-provider
 */

import {
    ExecutePromptParams,
    ExecutePromptResult,
    ModelConfig,
    ModelProgress,
    ModelProvider,
    ModelState,
    PlatformCapabilities
} from './types';

// ============================================================================
// MODEL CONFIGURATION
// Modify these values to use a different Transformers.js compatible model
// ============================================================================

/**
 * HuggingFace model ID for EmbeddingGemma
 * Change this to use a different model from HuggingFace
 */
const MODEL_ID = 'Xenova/all-MiniLM-L6-v2'; // Fallback model that works well in browser
// TODO: Switch to actual EmbeddingGemma when ONNX weights are available:
// const MODEL_ID = 'google/embedding-gemma';

/**
 * Whether to use quantized model weights
 * Quantized models are smaller and faster but slightly less accurate
 */
const USE_QUANTIZED = true;

// ============================================================================
// PROVIDER IMPLEMENTATION
// ============================================================================

/**
 * EmbeddingGemma provider implementation
 * 
 * This provider uses Transformers.js to run an embedding model locally.
 * The model is cached in the browser's Cache API, persisting across
 * extension updates.
 */
export class GemmaProvider implements ModelProvider {
  readonly id: string;
  readonly name: string = 'EmbeddingGemma';
  readonly version: string = '1.0.0';

  private config: ModelConfig;
  private state: ModelState = 'uninitialized';
  private pipeline: any = null;
  private transformers: any = null;

  constructor(config: ModelConfig) {
    this.id = config.id;
    this.config = config;
  }

  async checkPlatformSupport(): Promise<PlatformCapabilities> {
    const platform = this.detectPlatform();
    
    let hasWebGPU = false;
    try {
      if ('gpu' in navigator) {
        const gpu = await (navigator as any).gpu?.requestAdapter();
        hasWebGPU = !!gpu;
      }
    } catch {
      hasWebGPU = false;
    }

    const hasWasm = typeof WebAssembly !== 'undefined';
    
    // This model can run with WASM, WebGPU is optional (faster)
    const canRunModel = hasWasm && 
      (platform === 'windows' || platform === 'macos' || 
       platform === 'linux' || platform === 'chromeos' || platform === 'unknown');

    return {
      platform,
      hasWebGPU,
      hasWasm,
      canRunModel,
      unsupportedReason: canRunModel ? undefined : 
        'This platform does not support local model execution'
    };
  }

  private detectPlatform(): PlatformCapabilities['platform'] {
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

  async initialize(onProgress?: (progress: ModelProgress) => void): Promise<void> {
    if (this.state === 'ready') {
      onProgress?.({ state: 'ready' });
      return;
    }

    try {
      this.state = 'downloading';
      onProgress?.({ 
        state: 'downloading', 
        downloadProgress: 0,
        currentFile: 'Loading Transformers.js...'
      });

      // Dynamically import Transformers.js
      // This allows the model to be loaded only when needed
      const { pipeline, env } = await import('@xenova/transformers');
      this.transformers = { pipeline, env };

      // Configure Transformers.js for Chrome extension environment
      // Models are cached in the Cache API, persisting across extension updates
      env.allowLocalModels = false;
      env.useBrowserCache = true;

      this.state = 'loading';
      onProgress?.({ 
        state: 'loading', 
        downloadProgress: 10,
        currentFile: `Loading ${MODEL_ID}...`
      });

      // Create the feature extraction pipeline
      // Change 'feature-extraction' to another task for different model types:
      // - 'text-generation' for LLMs
      // - 'text-classification' for classifiers
      // - 'fill-mask' for BERT-style models
      this.pipeline = await pipeline('feature-extraction', MODEL_ID, {
        quantized: USE_QUANTIZED,
        progress_callback: (progress: any) => {
          if (progress.status === 'downloading') {
            onProgress?.({
              state: 'downloading',
              downloadProgress: Math.round(progress.progress || 0),
              currentFile: progress.file || MODEL_ID
            });
          }
        }
      });

      this.state = 'ready';
      onProgress?.({ state: 'ready', downloadProgress: 100 });
      console.log('[GemmaProvider] Model loaded successfully');

    } catch (error) {
      this.state = 'error';
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      onProgress?.({
        state: 'error',
        errorMessage: `Failed to load model: ${errorMessage}`
      });
      console.error('[GemmaProvider] Failed to initialize:', error);
      throw error;
    }
  }

  async executePrompt(params: ExecutePromptParams): Promise<ExecutePromptResult> {
    const startTime = Date.now();

    if (!this.isReady() || !this.pipeline) {
      return {
        success: false,
        error: 'Model is not initialized. Call initialize() first.'
      };
    }

    try {
      // Run the embedding model on the input text
      // For embedding models, we generate embeddings that can be used
      // for similarity search, classification, etc.
      const output = await this.pipeline(params.prompt, {
        pooling: 'mean',
        normalize: true
      });

      // Convert embeddings to array
      const embeddings = Array.from(output.data);

      // For the MEVIR use case, we return the embeddings as a JSON string
      // The consumer can parse and use them for similarity comparisons
      const response = JSON.stringify({
        embeddings: embeddings.slice(0, 10), // First 10 for brevity
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
      console.error('[GemmaProvider] Execution error:', error);
      return {
        success: false,
        error: errorMessage,
        executionTimeMs: Date.now() - startTime
      };
    }
  }

  isReady(): boolean {
    return this.state === 'ready' && this.pipeline !== null;
  }

  getState(): ModelState {
    return this.state;
  }

  async unload(): Promise<void> {
    if (this.pipeline) {
      // Transformers.js doesn't have explicit unload, but we can null the reference
      this.pipeline = null;
      this.transformers = null;
      this.state = 'uninitialized';
      console.log('[GemmaProvider] Model unloaded');
    }
  }
}

