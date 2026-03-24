# Complete Flake Template
#
# A production-ready flake.nix with devShell, package, overlay, NixOS module,
# and CI checks. Customize by replacing TODO markers.
#
# Usage:
#   nix develop       — Enter development shell
#   nix build         — Build default package
#   nix flake check   — Run all checks
#   nix run           — Run the application

{
  description = "TODO: Project description";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Optional: add more inputs
    # home-manager = {
    #   url = "github:nix-community/home-manager";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    # Per-system outputs (packages, devShells, apps, checks)
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
          # config.allowUnfree = true;  # Uncomment if needed
        };
        lib = pkgs.lib;
      in {
        # ── Packages ──────────────────────────────────────────────
        packages = {
          default = pkgs.callPackage ./package.nix {};
          # other-pkg = pkgs.callPackage ./other.nix {};
        };

        # ── Development Shell ─────────────────────────────────────
        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.default ];
          packages = with pkgs; [
            # Development tools
            nixfmt-rfc-style          # Nix formatter
            nil                       # Nix language server
            # TODO: add language-specific tools
          ];

          shellHook = ''
            echo "🛠  Development shell loaded"
            export PROJECT_ROOT="$PWD"
          '';
        };

        # ── Apps ──────────────────────────────────────────────────
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/TODO-binary-name";
        };

        # ── Checks (run with nix flake check) ─────────────────────
        checks = {
          # Build the package as a check
          build = self.packages.${system}.default;

          # Nix formatting check
          formatting = pkgs.runCommand "check-formatting" {
            nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
          } ''
            nixfmt --check ${self}/*.nix || {
              echo "Run 'nix fmt' to fix formatting"
              exit 1
            }
            touch $out
          '';

          # TODO: add project-specific checks
          # tests = pkgs.runCommand "tests" {
          #   buildInputs = [ self.packages.${system}.default ];
          # } ''
          #   TODO-binary-name --test
          #   touch $out
          # '';
        };

        # ── Formatter (run with nix fmt) ──────────────────────────
        formatter = pkgs.nixfmt-rfc-style;
      }
    ) // {
      # ── Non-per-system outputs ────────────────────────────────

      # ── Overlay ─────────────────────────────────────────────────
      overlays.default = final: prev: {
        # Add or override packages globally
        # my-tool = final.callPackage ./package.nix {};
      };

      # ── NixOS Module ────────────────────────────────────────────
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.TODO-service-name;
        in {
          options.services.TODO-service-name = {
            enable = lib.mkEnableOption "TODO service description";

            port = lib.mkOption {
              type = lib.types.port;
              default = 8080;
              description = "Port to listen on";
            };

            package = lib.mkPackageOption pkgs "TODO-package-name" {};
          };

          config = lib.mkIf cfg.enable {
            systemd.services.TODO-service-name = {
              description = "TODO Service";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];
              serviceConfig = {
                ExecStart = "${cfg.package}/bin/TODO-binary-name --port ${toString cfg.port}";
                DynamicUser = true;
                Restart = "on-failure";
                RestartSec = 5;
                # Hardening
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
              };
            };
            networking.firewall.allowedTCPPorts = [ cfg.port ];
          };
        };

      # ── NixOS Configuration (optional) ──────────────────────────
      # nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      #   system = "x86_64-linux";
      #   modules = [
      #     self.nixosModules.default
      #     { services.TODO-service-name.enable = true; }
      #   ];
      # };
    };
}
