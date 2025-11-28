const path = require('path');
const CopyPlugin = require('copy-webpack-plugin');
const TerserPlugin = require('terser-webpack-plugin');

module.exports = {
  entry: {
    content: './src/content.ts',
    background: './src/background.ts',
    popup: './src/popup.ts',
    offscreen: './src/offscreen.ts'
  },
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: '[name].js',
    // Chrome extensions don't allow filenames starting with underscore
    // Use numeric chunk IDs instead of the default naming
    chunkFilename: '[id].js',
    clean: true
  },
  module: {
    rules: [
      {
        test: /\.ts$/,
        use: 'ts-loader',
        exclude: /node_modules/
      }
    ]
  },
  resolve: {
    extensions: ['.ts', '.js']
  },
  plugins: [
    new CopyPlugin({
      patterns: [
        { from: 'manifest.json', to: 'manifest.json' },
        { from: 'popup.html', to: 'popup.html' },
        { from: 'popup.css', to: 'popup.css' },
        { from: 'src/offscreen.html', to: 'offscreen.html' },
        { from: 'icons', to: 'icons', noErrorOnMissing: true },
        // Copy ONNX Runtime WASM files for the ML model
        {
          from: 'node_modules/onnxruntime-web/dist/*.wasm',
          to: '[name][ext]'
        }
      ]
    })
  ],
  // Emit full source maps. Use Terser configured to "beautify" output
  // so bundles are formatted across multiple lines for easier debugging.
  optimization: {
    // Use deterministic chunk IDs to avoid underscore-prefixed filenames
    // Chrome extensions don't allow filenames starting with underscore
    chunkIds: 'deterministic',
    moduleIds: 'deterministic',
    minimize: true,
    minimizer: [
      new TerserPlugin({
        terserOptions: {
          compress: false,
          mangle: false,
          format: {
            beautify: true,
            comments: false
          }
        }
      })
    ]
  },
  devtool: 'source-map'
};

