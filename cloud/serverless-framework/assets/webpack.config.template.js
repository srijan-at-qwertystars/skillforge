// =============================================================================
// webpack.config.template.js — Serverless Webpack configuration for TypeScript
// =============================================================================
//
// Usage: Copy to your project root as webpack.config.js
// Requires: npm i -D serverless-webpack webpack webpack-node-externals ts-loader
//           fork-ts-checker-webpack-plugin
//
// In serverless.yml:
//   build:
//     esbuild: false              # Disable built-in esbuild in v4
//   plugins:
//     - serverless-webpack
//     - serverless-offline         # Must be after webpack
//   custom:
//     webpack:
//       webpackConfig: ./webpack.config.js
//       includeModules: true       # Include prod dependencies
//       packager: npm              # or 'yarn' or 'pnpm'
// =============================================================================

const path = require('path');
const slsw = require('serverless-webpack');
const nodeExternals = require('webpack-node-externals');
const ForkTsCheckerWebpackPlugin = require('fork-ts-checker-webpack-plugin');

const isLocal = slsw.lib.webpack.isLocal;

module.exports = {
  context: __dirname,
  mode: isLocal ? 'development' : 'production',
  entry: slsw.lib.entries,

  // Generate source maps for debugging
  devtool: isLocal ? 'eval-cheap-module-source-map' : 'source-map',

  resolve: {
    extensions: ['.ts', '.js', '.json'],
    alias: {
      '@': path.resolve(__dirname, 'src'),
    },
    symlinks: false,
    cacheWithContext: false,
  },

  output: {
    libraryTarget: 'commonjs2',
    path: path.join(__dirname, '.webpack'),
    filename: '[name].js',
  },

  target: 'node',

  // Exclude aws-sdk (provided in Lambda runtime) and node_modules
  externals: [
    nodeExternals({
      allowlist: [
        // Allowlist packages that need to be bundled (e.g., ESM-only packages)
        // /^@myorg\/.*/,
      ],
    }),
    // AWS SDK v3 is included in Node.js 18+ Lambda runtime
    /^@aws-sdk\/.*/,
  ],

  module: {
    rules: [
      {
        test: /\.ts$/,
        exclude: /node_modules/,
        use: [
          {
            loader: 'ts-loader',
            options: {
              // Use transpileOnly for faster builds; type checking via plugin
              transpileOnly: true,
              experimentalWatchApi: true,
            },
          },
        ],
      },
    ],
  },

  plugins: [
    // Run TypeScript type checking in a separate process
    new ForkTsCheckerWebpackPlugin({
      typescript: {
        diagnosticOptions: {
          semantic: true,
          syntactic: true,
        },
      },
    }),
  ],

  optimization: {
    // Don't minimize in development for easier debugging
    minimize: !isLocal,
    // Keep module concatenation for tree-shaking
    concatenateModules: true,
  },

  // Ignore optional/native dependencies that cause warnings
  stats: isLocal ? 'minimal' : 'normal',
  ignoreWarnings: [
    { module: /node_modules/ },
  ],
};
