/**
 * Model Types and Interfaces
 * 
 * This file defines the abstraction layer for language models.
 * To change the underlying model, implement the ModelProvider interface
 * with your new model and update the provider in model-manager.ts.
 * 
 * @module models/types
 */

/**
 * Supported platform architectures for model execution.
 * Not all models support all platforms.
 */
export type PlatformType = 
  | 'windows'
  | 'macos'
  | 'linux'
  | 'android'
  | 'ios'
  | 'chromeos'
  | 'unknown';

/**
 * Model execution backend capabilities
 */
export interface PlatformCapabilities {
  /** Platform identifier */
  platform: PlatformType;
  /** Whether WebGPU is available for GPU acceleration */
  hasWebGPU: boolean;
  /** Whether WebAssembly is available (required for most models) */
  hasWasm: boolean;
  /** Whether the platform can run the model */
  canRunModel: boolean;
  /** Reason if model cannot run */
  unsupportedReason?: string;
}

/**
 * Model loading and execution state
 */
export type ModelState = 
  | 'uninitialized'
  | 'downloading'
  | 'loading'
  | 'ready'
  | 'error'
  | 'unsupported';

/**
 * Model download/loading progress information
 */
export interface ModelProgress {
  /** Current state of the model */
  state: ModelState;
  /** Download progress percentage (0-100) */
  downloadProgress?: number;
  /** Name of the file currently being downloaded */
  currentFile?: string;
  /** Error message if state is 'error' */
  errorMessage?: string;
}

/**
 * Parameters for ExecutePrompt function
 * 
 * To add new parameters for a different model:
 * 1. Add optional parameters here
 * 2. Handle them in your ModelProvider implementation
 */
export interface ExecutePromptParams {
  /** The prompt/input text to process */
  prompt: string;
  /** Maximum tokens to generate (if applicable) */
  maxTokens?: number;
  /** Temperature for generation (0-1, lower = more deterministic) */
  temperature?: number;
  /** System prompt/context (if supported by model) */
  systemPrompt?: string;
}

/**
 * Result from ExecutePrompt function
 * 
 * To add new result fields for a different model:
 * 1. Add optional fields here
 * 2. Populate them in your ModelProvider implementation
 */
export interface ExecutePromptResult {
  /** Whether the execution succeeded */
  success: boolean;
  /** The generated response/output text */
  response?: string;
  /** Error message if success is false */
  error?: string;
  /** Execution time in milliseconds */
  executionTimeMs?: number;
  /** Number of tokens generated (if applicable) */
  tokensGenerated?: number;
}

/**
 * Model Provider Interface
 * 
 * Implement this interface to add support for a new language model.
 * 
 * Steps to add a new model:
 * 1. Create a new file (e.g., my-model-provider.ts)
 * 2. Implement all methods of this interface
 * 3. Update model-manager.ts to use your new provider
 * 4. Update MODEL_CONFIG in model-manager.ts with model details
 */
export interface ModelProvider {
  /** Unique identifier for this model provider */
  readonly id: string;
  
  /** Human-readable name of the model */
  readonly name: string;
  
  /** Model version string */
  readonly version: string;

  /**
   * Check if the model is supported on the current platform
   * @returns Platform capabilities and support status
   */
  checkPlatformSupport(): Promise<PlatformCapabilities>;

  /**
   * Initialize and download the model if needed.
   * Models should be cached to avoid re-downloading on extension updates.
   * 
   * @param onProgress - Callback for progress updates
   * @returns Promise that resolves when model is ready
   */
  initialize(onProgress?: (progress: ModelProgress) => void): Promise<void>;

  /**
   * Execute a prompt using the model
   * 
   * @param params - Prompt parameters
   * @returns Promise with the execution result
   */
  executePrompt(params: ExecutePromptParams): Promise<ExecutePromptResult>;

  /**
   * Check if the model is currently ready for execution
   */
  isReady(): boolean;

  /**
   * Get current model state
   */
  getState(): ModelState;

  /**
   * Unload the model from memory (optional cleanup)
   */
  unload(): Promise<void>;
}

/**
 * Configuration for a model provider
 * 
 * Update this when adding a new model to specify its requirements
 */
export interface ModelConfig {
  /** Unique identifier matching the provider's id */
  id: string;
  /** HuggingFace model repository path */
  modelPath: string;
  /** Minimum RAM required in MB */
  minRamMB: number;
  /** Supported platforms (empty = all platforms with required capabilities) */
  supportedPlatforms?: PlatformType[];
  /** Whether the model requires WebGPU (vs WASM-only) */
  requiresWebGPU: boolean;
}

