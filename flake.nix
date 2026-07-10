{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    zmk-nix = {
      url = "github:lilyinstarlight/zmk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Local west/Zephyr compilation environment, matching the companion
    # zmk-keyboard-cornix flake's dev shell approach.
    zephyr.url = "github:zephyrproject-rtos/zephyr/v3.7.0";
    zephyr.flake = false;

    zephyr-nix = {
      url = "github:urob/zephyr-nix";
      inputs.zephyr.follows = "zephyr";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    keymap_drawer-nix = {
      url = "github:hitsmaxft/keymap-drawer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zmk-nix, zephyr-nix, keymap_drawer-nix, ... }: let
    forAllSystems = nixpkgs.lib.genAttrs (nixpkgs.lib.attrNames zmk-nix.packages);
  in {
    packages = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        firmware = zmk-nix.legacyPackages.${system}.buildSplitKeyboard {
          name = "firmware";

          src = nixpkgs.lib.sourceFilesBySuffices self [ ".board" ".cmake" ".conf" ".defconfig" ".dts" ".dtsi" ".json" ".keymap" ".overlay" ".shield" ".yml" "_defconfig" ];

          board = "eyelash_corne_%PART%";
          shield = "nice_view";


          zephyrDepsHash = "sha256-PAx4ovahXeGm8ihicGvI0v+q7urfkjnmj09thuluFRs=";

          meta = {
            description = "ZMK firmware";
            license = nixpkgs.lib.licenses.mit;
            platforms = nixpkgs.lib.platforms.all;
          };
        };
      in {
        default = firmware;
        inherit firmware;
        update = zmk-nix.packages.${system}.update;
      } // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        flash = zmk-nix.packages.${system}.flash.override { inherit firmware; };
      });

    devShells = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zephyr = zephyr-nix.packages.${system};
        zephyrPyEnv = zephyr.pythonEnv;
        zephyrSdk = zephyr.sdk-0_16.override { targets = [ "arm-zephyr-eabi" ]; };
        keymap_drawer = keymap_drawer-nix.packages.${system}.default;
        pythonProtobuf = pkgs.python312Packages.protobuf;

        commonRuntimeInputs = with pkgs; [
          git
          coreutils
          findutils
          gnugrep
          gnused
          cmake
          dtc
          ninja
          protobuf
          zephyrPyEnv
          zephyrSdk
        ];

        zmk-local-init = pkgs.writeShellApplication {
          name = "zmk-local-init";
          runtimeInputs = commonRuntimeInputs;
          text = ''
            set -euo pipefail

            if [[ ! -f config/west.yml ]]; then
              echo "Run this from the zmk-new_corne repository root." >&2
              exit 1
            fi

            export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
            export ZEPHYR_SDK_INSTALL_DIR=${zephyrSdk}

            if [[ ! -d .west ]]; then
              west init -l config
            fi

            find . -path '*/.git/index.lock' -delete 2>/dev/null || true
            west update --fetch-opt=--filter=blob:none
            west zephyr-export
          '';
        };

        zmk-local-build = pkgs.writeShellApplication {
          name = "zmk-local-build";
          runtimeInputs = commonRuntimeInputs;
          text = ''
            set -euo pipefail

            if [[ ! -f config/west.yml ]]; then
              echo "Run this from the zmk-new_corne repository root." >&2
              exit 1
            fi

            if [[ ! -d .west || ! -d zmk || ! -d zephyr ]]; then
              echo "West workspace is not initialized. Run: zmk-local-init" >&2
              exit 1
            fi

            export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
            export ZEPHYR_SDK_INSTALL_DIR=${zephyrSdk}
            export PYTHONPATH="${pythonProtobuf}/${pkgs.python312.sitePackages}:''${PYTHONPATH:-}"

            target="''${1:-all}"

            build_right() {
              west build -s zmk/app -d build/eyelash_corne_right \
                -b eyelash_corne_right -- \
                -DZMK_CONFIG="$PWD/config" \
                -DSHIELD=nice_view
            }

            build_studio_left() {
              west build -s zmk/app -d build/eyelash_corne_studio_left \
                -b eyelash_corne_left \
                -S studio-rpc-usb-uart -- \
                -DZMK_CONFIG="$PWD/config" \
                -DSHIELD=nice_view \
                -DCONFIG_ZMK_STUDIO=y \
                -DCONFIG_ZMK_STUDIO_LOCKING=n
            }

            build_reset() {
              west build -s zmk/app -d build/eyelash_corne_settings_reset \
                -b eyelash_corne_left -- \
                -DZMK_CONFIG="$PWD/config" \
                -DSHIELD=settings_reset
            }

            collect_artifacts() {
              mkdir -p firmware
              [[ -f build/eyelash_corne_right/zephyr/zmk.uf2 ]] && \
                cp build/eyelash_corne_right/zephyr/zmk.uf2 firmware/eyelash_corne_right.uf2
              [[ -f build/eyelash_corne_studio_left/zephyr/zmk.uf2 ]] && \
                cp build/eyelash_corne_studio_left/zephyr/zmk.uf2 firmware/eyelash_corne_studio_left.uf2
              [[ -f build/eyelash_corne_settings_reset/zephyr/zmk.uf2 ]] && \
                cp build/eyelash_corne_settings_reset/zephyr/zmk.uf2 firmware/eyelash_corne_settings_reset.uf2
              ls -lh firmware/*.uf2 2>/dev/null || true
            }

            case "$target" in
              right)
                build_right
                collect_artifacts
                ;;
              studio-left|left|studio)
                build_studio_left
                collect_artifacts
                ;;
              reset|settings-reset)
                build_reset
                collect_artifacts
                ;;
              all|default)
                build_right
                build_studio_left
                build_reset
                collect_artifacts
                ;;
              *)
                echo "Usage: zmk-local-build [all|right|studio-left|reset]" >&2
                exit 2
                ;;
            esac
          '';
        };

        zmk-local-clean = pkgs.writeShellApplication {
          name = "zmk-local-clean";
          runtimeInputs = with pkgs; [ coreutils findutils ];
          text = ''
            set -euo pipefail

            if [[ ! -f config/west.yml ]]; then
              echo "Run this from the zmk-new_corne repository root." >&2
              exit 1
            fi

            target="''${1:-build}"

            case "$target" in
              build)
                rm -rf build firmware
                ;;
              deps|west-deps)
                rm -rf eyelash_corne zmk zephyr modules tools bootloader
                find . -path '*/.git/index.lock' -delete 2>/dev/null || true
                ;;
              all)
                rm -rf build firmware eyelash_corne zmk zephyr modules tools bootloader
                find . -path '*/.git/index.lock' -delete 2>/dev/null || true
                ;;
              *)
                echo "Usage: zmk-local-clean [build|deps|all]" >&2
                exit 2
                ;;
            esac
          '';
        };
      in {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            gcovr
            gcc-arm-embedded
            zephyrPyEnv
            zephyrSdk
            cmake
            dtc
            ninja
            just
            yq
            tio
            keymap_drawer
            zmk-local-init
            zmk-local-build
            zmk-local-clean
          ];

          # Never export ZEPHYR_BASE; west owns it. Zephyr_DIR is useful for CMake tooling.
          shellHook = ''
            export ZMK_LIB_PREFIX="''${ZMK_LIB_PREFIX:=zmk_exts}"
            export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
            export ZEPHYR_SDK_INSTALL_DIR=${zephyrSdk}

            if west config zephyr.base >/dev/null 2>&1; then
              Zephyr_DIR="$(west config zephyr.base)/share/zephyr-package/cmake/"
              export Zephyr_DIR
            fi

            echo "Local ZMK commands: zmk-local-init, zmk-local-build [all|right|studio-left|reset], zmk-local-clean [build|deps|all]"
          '';
        };
      });
  };
}
