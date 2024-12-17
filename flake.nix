{
  description = "z8lua";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        rustToolchain = toolchain:
          let
            rustToolchain = pkgs.rust-bin.${toolchain}.latest.default.override {
              targets = [
                "wasm32-wasip1"
              ];
            };
          in
          if builtins.hasAttr toolchain pkgs.rust-bin then
            rustToolchain
          else
            throw "Unsupported Rust toolchain: ${toolchain}";

        wasm-tools = with pkgs; rustPlatform.buildRustPackage rec {
          pname = "wasm-tools";
          version = "1.217.0";

          src = fetchFromGitHub {
            owner = "bytecodealliance";
            repo = "wasm-tools";
            rev = "v${version}";
            hash = "sha256-nxfYoR0ba0As00WbahSVFNItSlleMmITqs8eJabjD/U=";
            fetchSubmodules = true;
          };

          # Disable cargo-auditable until https://github.com/rust-secure-code/cargo-auditable/issues/124 is solved.
          auditable = false;

          cargoHash = "sha256-mBSRJYSE3HmeWhnW4nFF8uFnUJaZ6wdqsq+GnL6SZWc=";
          cargoBuildFlags = [ "--package" "wasm-tools" ];
          cargoTestFlags = [ "--all" ];
        };

        common-build-inputs = with pkgs; [
          binaryen
          clang
          cmake
          gnused
          ninja
          pkg-config
          python3
          readline
          wasi-sdk
        ] ++ lib.optionals stdenv.isDarwin [
          darwin.apple_sdk.frameworks.SystemConfiguration
          darwin.apple_sdk.frameworks.Security
        ];

        common-dev-tools = [
          wasm-tools
        ];

        rust-toolchain = rustToolchain "stable";

        rust-platform = pkgs.makeRustPlatform {
          cargo = rust-toolchain;
          rustc = rust-toolchain;
        };

        wasm-component-ld = rust-platform.buildRustPackage
          rec {
            pname = "wasm-component-ld";
            version = "0.5.6";

            src = pkgs.fetchCrate {
              inherit pname version;
              sha256 = "sha256-97UizuYCm4Riu4rtGHx0Ts6XRjqb4ZRMeZFENpa4HP0=";
            };

            cargoHash = "sha256-2wSJ1YPXYhc2YCKfm0gqpcmkWjKP3jaDyVB7n7rRgBE=";
          };

        cargoWrapper = with pkgs; writeScriptBin "cargo-wrapper.sh" ''
          #!/usr/bin/env bash
          set -x
          echo "derp"
          mkdir -p /build/wasi-sdk/build/toolchain/wasm-component-ld/bin
          cp -r ${wasm-component-ld}/bin/* /build/wasi-sdk/build/toolchain/wasm-component-ld/bin
        '';

        wrapped-cargo = with pkgs; stdenv.mkDerivation
          {
            name = "cargo";
            buildInputs = [ cargo makeWrapper ];

            dontUnpack = true;
            dontBuild = true;

            installPhase = ''
              mkdir -p $out/bin
              cp ${cargoWrapper}/bin/cargo-wrapper.sh $out/bin/
              chmod +x $out/bin/cargo-wrapper.sh
    
              makeWrapper $out/bin/cargo-wrapper.sh $out/bin/cargo \
                --prefix PATH : ${cargo}/bin
            '';

            meta = {
              description = "A wrapped version of git that intercepts the describe command";
              platforms = cargo.meta.platforms;
            };
          };

        gitWrapper = with pkgs; writeScriptBin "git-wrapper.sh" ''
          #!/usr/bin/env bash
    
          handle_describe() {
            echo "wasi-sdk-24-0"
          }

          handle_revparse() {
            echo "d2bea01edcc4"
          }
    
          case "$1" in
            "describe")
              shift
              handle_describe "$@"
              ;;
            "rev-parse")
              shift
              handle_revparse "$@"
              ;;
            *)
              # Pass through all other commands directly to git
              exec ${git}/bin/git "$@"
              ;;
          esac
        '';

        wrapped-git = with pkgs; stdenv.mkDerivation
          {
            name = "git";
            buildInputs = [ git makeWrapper ];

            dontUnpack = true;
            dontBuild = true;

            installPhase = ''
              mkdir -p $out/bin
              # Copy our wrapper script
              cp ${gitWrapper}/bin/git-wrapper.sh $out/bin/
              chmod +x $out/bin/git-wrapper.sh
    
              # Use makeWrapper to create the final wrapped git command
              makeWrapper $out/bin/git-wrapper.sh $out/bin/git \
                --prefix PATH : ${git}/bin
            '';

            meta = {
              description = "A wrapped version of git that intercepts the describe command";
              platforms = git.meta.platforms;
            };
          };

        wasi-sdk = with pkgs;
          clangStdenv.mkDerivation rec {
            name = "wasi-sdk";
            pname = "wasi-sdk";

            src = fetchgit
              {
                url = "https://github.com/WebAssembly/wasi-sdk.git";
                rev = "refs/tags/wasi-sdk-24";
                fetchSubmodules = true;
                hash = "sha256-XayudziglVWExMvM21L/sUdYJjR7PlSEwhbS9WQY+8w=";
                postFetch = ''
              '';
              };

            nativeBuildInputs = [
              # cargo
              # ccache
              wrapped-cargo
              clang
              cmake
              wrapped-git
              ninja
              python3
              tree
              wasm-component-ld
            ];

            buildPhase = ''
              echo "`pwd`"
              cd ../
              cmake -G Ninja -B build/toolchain -S . -DWASI_SDK_BUILD_TOOLCHAIN=ON -DCMAKE_INSTALL_PREFIX=build/install
              cmake --build build/toolchain --target install
            '';

            installPhase = ''
              mkdir -p $out/
              cp -r ./build/install/* $out
            '';
          };

      in
      {
        devShells = {
          default = with pkgs; mkShell {
            buildInputs = common-build-inputs ++ common-dev-tools;

            # LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [];

            # env = {};

            shellHook = ''
            '';
          };
        };

        packages = { };
      });
}
