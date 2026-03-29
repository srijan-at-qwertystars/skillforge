# Rspack References

## Official Documentation

- **Rspack Docs** - https://rspack.dev/
  - Main documentation site with guides, API reference, and configuration
- **Rspack Configuration** - https://rspack.dev/config/
  - Complete configuration options reference
- **Rspack CLI** - https://rspack.dev/api/cli
  - Command-line interface documentation
- **Rspack Plugins** - https://rspack.dev/plugins/
  - Built-in and community plugins

## GitHub Repositories

- **Rspack (main repo)** - https://github.com/web-infra-dev/rspack
  - The core Rspack bundler written in Rust
- **Rspack Plugins** - https://github.com/web-infra-dev/rspack-plugins
  - Official plugin collection
- **Rspack Examples** - https://github.com/web-infra-dev/rspack-examples
  - Example projects and starter templates
- **Rsbuild** - https://github.com/web-infra-dev/rsbuild
  - Build tool based on Rspack (higher-level abstraction)
- **Rsdoctor** - https://github.com/web-infra-dev/rsdoctor
  - Build analyzer for Rspack and webpack

## Related Tools

### SWC (Speedy Web Compiler)
- **SWC Docs** - https://swc.rs/
- **SWC GitHub** - https://github.com/swc-project/swc
- Rspack uses SWC internally for JavaScript/TypeScript transformation
- Built-in `builtin:swc-loader` replaces babel-loader

### Webpack (Compatibility Reference)
- **Webpack Docs** - https://webpack.js.org/
- **Webpack GitHub** - https://github.com/webpack/webpack
- Rspack maintains API compatibility with webpack
- Most webpack plugins work with Rspack

### Lightning CSS
- **Lightning CSS** - https://lightcss.dev/
- Used by Rspack for CSS minification via `LightningCssMinimizerRspackPlugin`

### Related Web-Infra Projects
- **Modern.js** - https://github.com/web-infra-dev/modern.js
  - Web engineering system from ByteDance
- **Garfish** - https://github.com/web-infra-dev/garfish
  - Micro-frontend framework
- **Rstack** - https://github.com/rspack-contrib/
  - Community contributions and ecosystem

## Migration Resources

- **Webpack to Rspack Migration** - https://rspack.dev/guide/migration/webpack
- **CRA Migration** - https://rspack.dev/guide/migration/cra
- **Vue CLI Migration** - https://rspack.dev/guide/migration/vue-cli

## Community & Support

- **Discord** - https://discord.gg/79ZZ66Z9VX
- **Twitter/X** - https://twitter.com/rspack_dev
- **Web Infra Community** - https://github.com/web-infra-dev
