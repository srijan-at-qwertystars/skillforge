---
name: rspack-bundler
description: |
  Fast Rust-based bundler with webpack compatibility. Use for high-performance builds.
  NOT for simple projects where Vite suffices.
tested: 2026-03-29
---

# Rspack

Rust-powered webpack alternative. 5-10x faster builds, full webpack API compatibility, built-in SWC.

## Quick Start

```bash
# Init project
npm create rspack@latest my-app
cd my-app && npm install

# Dev server
npx rspack serve

# Production build
npx rspack build
```

## Configuration (rspack.config.js)

```javascript
const rspack = require('@rspack/core');

module.exports = {
  entry: './src/index.js',
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: '[name].[contenthash:8].js',
    clean: true
  },
  mode: 'production',
  
  // Built-in SWC (no babel needed)
  module: {
    rules: [
      {
        test: /\.jsx?$/,
        use: {
          loader: 'builtin:swc-loader',
          options: {
            jsc: {
              parser: { syntax: 'ecmascript', jsx: true },
              transform: { react: { runtime: 'automatic' } }
            }
          }
        }
      },
      {
        test: /\.tsx?$/,
        use: {
          loader: 'builtin:swc-loader',
          options: {
            jsc: {
              parser: { syntax: 'typescript', tsx: true },
              transform: { react: { runtime: 'automatic' } }
            }
          }
        }
      },
      {
        test: /\.css$/,
        use: ['style-loader', 'css-loader', 'postcss-loader']
      },
      {
        test: /\.(png|svg|jpg)$/,
        type: 'asset/resource'
      }
    ]
  },
  
  plugins: [
    new rspack.HtmlRspackPlugin({ template: './public/index.html' }),
    new rspack.DefinePlugin({ 'process.env.NODE_ENV': JSON.stringify('production') })
  ],
  
  optimization: {
    splitChunks: {
      chunks: 'all',
      cacheGroups: {
        vendor: {
          test: /[\\/]node_modules[\\/]/,
          name: 'vendors',
          chunks: 'all'
        }
      }
    }
  },
  
  devServer: {
    port: 3000,
    hot: true,
    open: true
  }
};
```

## TypeScript Config

```typescript
// rspack.config.ts
import { Configuration } from '@rspack/core';

const config: Configuration = {
  entry: './src/index.ts',
  module: {
    rules: [
      {
        test: /\.ts$/,
        use: 'builtin:swc-loader'
      }
    ]
  }
};

export default config;
```

## React Integration

```javascript
// rspack.config.js
module.exports = {
  module: {
    rules: [
      {
        test: /\.[jt]sx$/,
        use: {
          loader: 'builtin:swc-loader',
          options: {
            jsc: {
              parser: { syntax: 'typescript', tsx: true },
              transform: {
                react: {
                  runtime: 'automatic',
                  development: process.env.NODE_ENV === 'development',
                  refresh: process.env.NODE_ENV === 'development'
                }
              }
            }
          }
        }
      }
    ]
  },
  plugins: [
    process.env.NODE_ENV === 'development' && 
      new rspack.ReactRefreshPlugin()
  ].filter(Boolean)
};
```

## Vue Integration

```javascript
const { VueLoaderPlugin } = require('vue-loader');

module.exports = {
  module: {
    rules: [
      { test: /\.vue$/, use: 'vue-loader' },
      { test: /\.css$/, use: ['vue-style-loader', 'css-loader'] }
    ]
  },
  plugins: [new VueLoaderPlugin()]
};
```

## Webpack Plugin Compatibility

```javascript
// Most webpack plugins work unchanged
const MiniCssExtractPlugin = require('mini-css-extract-plugin');
const CopyPlugin = require('copy-webpack-plugin');
const TerserPlugin = require('terser-webpack-plugin');

module.exports = {
  plugins: [
    new MiniCssExtractPlugin({ filename: '[name].css' }),
    new CopyPlugin({ patterns: [{ from: 'public', to: 'static' }] })
  ],
  optimization: {
    minimizer: [new TerserPlugin()]
  }
};
```

## Performance Optimization

```javascript
module.exports = {
  // Parallel builds (auto-detected cores)
  parallelism: require('os').cpus().length,
  
  // Persistent caching
  cache: {
    type: 'filesystem',
    buildDependencies: { config: [__filename] }
  },
  
  // Faster source maps for dev
  devtool: process.env.NODE_ENV === 'development' ? 'eval-cheap-source-map' : 'source-map',
  
  // Tree shaking
  optimization: {
    usedExports: true,
    sideEffects: false,
    providedExports: true,
    innerGraph: true
  },
  
  // Module federation
  experiments: {
    outputModule: true
  }
};
```

## SWC Configuration

```javascript
// .swcrc or inline
{
  "jsc": {
    "target": "es2022",
    "parser": {
      "syntax": "typescript",
      "tsx": true,
      "decorators": true,
      "dynamicImport": true
    },
    "transform": {
      "react": { "runtime": "automatic" },
      "legacyDecorator": true,
      "decoratorMetadata": true
    },
    "experimental": {
      "plugins": [["@swc/plugin-styled-components", {}]]
    }
  },
  "module": { "type": "es6" },
  "minify": true
}
```

## Module Federation

```javascript
const { ModuleFederationPlugin } = require('@rspack/core').container;

module.exports = {
  plugins: [
    new ModuleFederationPlugin({
      name: 'host',
      remotes: {
        app1: 'app1@http://localhost:3001/remoteEntry.js'
      },
      shared: {
        react: { singleton: true, eager: true },
        'react-dom': { singleton: true }
      }
    })
  ]
};
```

## CSS/SCSS Setup

```javascript
module.exports = {
  module: {
    rules: [
      {
        test: /\.s[ac]ss$/i,
        use: [
          'style-loader',
          { loader: 'css-loader', options: { modules: true } },
          'sass-loader'
        ]
      },
      {
        test: /\.css$/,
        use: [
          rspack.CssExtractRspackPlugin.loader,
          'css-loader',
          'postcss-loader'
        ]
      }
    ]
  },
  plugins: [
    new rspack.CssExtractRspackPlugin({ filename: '[name].css' })
  ]
};
```

## Environment Variables

```javascript
const rspack = require('@rspack/core');

module.exports = {
  plugins: [
    new rspack.DefinePlugin({
      'process.env.API_URL': JSON.stringify(process.env.API_URL),
      'process.env.DEBUG': JSON.stringify(process.env.NODE_ENV === 'development')
    }),
    new rspack.EnvironmentPlugin(['NODE_ENV', 'API_KEY'])
  ]
};
```

## Build Analysis

```bash
# Bundle analyzer
npm install @rspack/cli --save-dev
npx rspack build --analyze

# Stats output
npx rspack build --json > stats.json
```

## Common Patterns

### Lazy Loading
```javascript
const LazyComponent = React.lazy(() => import('./HeavyComponent'));
```

### Dynamic Imports with Preload
```javascript
import(/* webpackPreload: true */ './chunk.js');
```

### Worker Threads
```javascript
const worker = new Worker(new URL('./worker.js', import.meta.url));
```

## Migration from Webpack

```bash
# 1. Replace webpack dependencies
npm uninstall webpack webpack-cli webpack-dev-server
npm install @rspack/core @rspack/cli

# 2. Rename config (optional)
mv webpack.config.js rspack.config.js

# 3. Replace babel-loader with builtin:swc-loader
# 4. Replace HtmlWebpackPlugin with HtmlRspackPlugin
# 5. Test build: npx rspack build
```

## CLI Commands

```bash
npx rspack build              # Production build
npx rspack serve              # Dev server with HMR
npx rspack build --watch      # Watch mode
npx rspack build --mode=none  # No optimization
npx rspack build --profile    # Performance profile
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| SWC parse error | Check `jsc.parser.syntax` matches file extension |
| Plugin not found | Verify webpack plugin version compatibility |
| Slow dev builds | Enable `experiments.lazyCompilation` |
| Memory issues | Reduce `parallelism` or enable `cache` |
| HMR not working | Ensure `devServer.hot: true` + ReactRefreshPlugin |

## Key Differences from Webpack

- `builtin:swc-loader` replaces `babel-loader`
- `HtmlRspackPlugin` replaces `HtmlWebpackPlugin`
- `CssExtractRspackPlugin` replaces `MiniCssExtractPlugin`
- Built-in `LightningCssMinimizerRspackPlugin` (faster than cssnano)
- No `webpack-dev-middleware` - use `@rspack/dev-server`
