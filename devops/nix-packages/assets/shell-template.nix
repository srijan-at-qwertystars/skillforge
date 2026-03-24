# Development Shell Template
#
# A reusable mkShell template with common tools and language support.
# Import this from your flake.nix:
#   devShells.default = import ./shell-template.nix { inherit pkgs; };
#
# Customize the language section and tool list for your project.

{ pkgs, lib ? pkgs.lib }:

let
  # ── Configure your project here ──────────────────────────────
  projectName = "my-project";

  # Toggle language support (set to true for your stack)
  enableNode = false;
  enablePython = false;
  enableRust = false;
  enableGo = false;
  enableCpp = false;

  # ── Language-specific packages ───────────────────────────────
  nodePackages = with pkgs; lib.optionals enableNode [
    nodejs_22
    nodePackages.pnpm
    nodePackages.typescript
    nodePackages.typescript-language-server
    nodePackages.prettier
  ];

  pythonPackages = with pkgs; lib.optionals enablePython [
    python312
    python312Packages.pip
    python312Packages.virtualenv
    ruff
    pyright
  ];

  rustPackages = with pkgs; lib.optionals enableRust [
    cargo
    rustc
    rust-analyzer
    clippy
    rustfmt
    cargo-watch
  ];

  goPackages = with pkgs; lib.optionals enableGo [
    go_1_22
    gopls
    gotools
    golangci-lint
    delve
  ];

  cppPackages = with pkgs; lib.optionals enableCpp [
    gcc
    cmake
    gnumake
    gdb
    clang-tools
  ];

  # ── Common development tools ─────────────────────────────────
  commonPackages = with pkgs; [
    # Version control & tools
    git
    jq
    yq
    curl
    wget

    # Nix tools
    nil                  # Nix language server
    nixfmt-rfc-style     # Nix formatter

    # Container tools (uncomment if needed)
    # docker-compose
    # kubectl
    # k9s
  ];

  # ── Build dependencies (C libraries, etc.) ───────────────────
  buildDeps = with pkgs; [
    # Uncomment libraries your project needs
    # openssl
    # zlib
    # sqlite
    # postgresql
  ] ++ lib.optionals pkgs.stdenv.isDarwin (with pkgs.darwin.apple_sdk.frameworks; [
    Security
    SystemConfiguration
    CoreServices
  ]);

in pkgs.mkShell {
  name = "${projectName}-shell";

  packages = commonPackages
    ++ nodePackages
    ++ pythonPackages
    ++ rustPackages
    ++ goPackages
    ++ cppPackages;

  buildInputs = buildDeps;

  nativeBuildInputs = with pkgs;
    lib.optionals (buildDeps != []) [ pkg-config ];

  # ── Environment variables ────────────────────────────────────
  # Add project-specific env vars here
  # DATABASE_URL = "postgresql://localhost/dev";
  # AWS_PROFILE = "dev";

  # Rust-specific
  RUST_SRC_PATH = lib.optionalString enableRust
    "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
  RUST_BACKTRACE = lib.optionalString enableRust "1";

  # Go-specific
  CGO_ENABLED = lib.optionalString enableGo "0";

  # ── Shell hook ───────────────────────────────────────────────
  shellHook = ''
    export PROJECT_ROOT="$PWD"

    # Node.js: add local binaries to PATH
    ${lib.optionalString enableNode ''
      export PATH="$PWD/node_modules/.bin:$PATH"
    ''}

    # Python: auto-create and activate venv
    ${lib.optionalString enablePython ''
      if [ ! -d .venv ]; then
        echo "Creating Python virtual environment..."
        python -m venv .venv
      fi
      source .venv/bin/activate
    ''}

    # Go: set up local GOPATH
    ${lib.optionalString enableGo ''
      export GOPATH="$PWD/.go"
      export GOBIN="$GOPATH/bin"
      export PATH="$GOBIN:$PATH"
      mkdir -p "$GOBIN"
    ''}

    # Load .env if present (never commit secrets!)
    if [ -f .env ] && [ -z "''${CI:-}" ]; then
      set -a
      source .env
      set +a
    fi

    echo "🛠  ${projectName} dev environment loaded"
  '';
}
