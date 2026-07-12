{
  description = "colibrì — run GLM-5.2 (744B MoE) on a consumer machine with ~25 GB RAM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Python with the packages needed by the offline converter tools
        pythonEnv = pkgs.python3.withPackages (ps: with ps; [
          torch
          safetensors
          huggingface-hub
          numpy
        ]);

        colibri = pkgs.stdenv.mkDerivation {
          pname = "colibri";
          version = "1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper pkgs.gcc ]
            ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.llvmPackages.openmp;

          buildInputs = pkgs.lib.optional pkgs.stdenv.isLinux pkgs.gmp;

          # Use x86-64-v3 (AVX2) for a portable binary; override with ARCH=native for local builds
          ARCH = if pkgs.stdenv.isDarwin then "native" else "x86-64-v3";

          buildPhase = let
            makeArgs = pkgs.lib.optionalString pkgs.stdenv.isDarwin
              "OMPDIR=${pkgs.llvmPackages.openmp}";
          in ''
            runHook preBuild
            make -C c glm ARCH="$ARCH" ${makeArgs}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp c/glm $out/bin/glm

            # Wrap coli (the Python CLI) so it finds the right python and the engine
            mkdir -p $out/share/colibri
            cp c/coli $out/share/colibri/coli
            chmod +x $out/share/colibri/coli
            cp -r c/tools $out/share/colibri/tools

            makeWrapper ${pythonEnv}/bin/python $out/bin/coli \
              --add-flags "$out/share/colibri/coli" \
              --set PYTHONPATH "${pythonEnv}/${pkgs.python3.sitePackages}"
            runHook postInstall
          '';

          checkPhase = ''
            runHook preCheck
            cd c
            make test-c
            cd ..
            runHook postCheck
          '';

          doCheck = true;

          meta = with pkgs.lib; {
            description = "Run GLM-5.2 (744B MoE) on a consumer machine with ~25 GB RAM";
            homepage = "https://github.com/JustVugg/colibri";
            license = licenses.asl20;
            platforms = platforms.linux ++ platforms.darwin;
            mainProgram = "glm";
          };
        };
      in
      rec {
        packages = {
          default = colibri;
          inherit colibri;
        };

        apps = {
          default = {
            type = "app";
            program = "${colibri}/bin/glm";
          };
          coli = {
            type = "app";
            program = "${colibri}/bin/coli";
          };
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ colibri ];

          packages = [
            pythonEnv
            pkgs.gcc
            pkgs.gnumake
            pkgs.pkg-config
          ] ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.clang-tools
            ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.llvmPackages.openmp;

          shellHook = ''
            echo "🐦 colibrì dev shell"
            echo "  gcc: $(gcc --version | head -1)"
            echo "  python: $(python3 --version)"
            echo ""
            echo "Build the engine:   make -C c glm"
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
            echo "  (on macOS: make -C c glm OMPDIR=${pkgs.llvmPackages.openmp})"
            ''}
            echo "Run the converter:  python c/coli convert --model /path/to/glm52_i4"
            echo "Chat:               COLI_MODEL=/path/to/glm52_i4 ./result/bin/glm"
          '';
        };
      }
    );
}
