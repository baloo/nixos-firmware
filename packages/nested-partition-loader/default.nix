{ pkgs ? null
, ...}:

let
  moz_overlay = import (builtins.fetchTarball https://github.com/mozilla/nixpkgs-mozilla/archive/0510159186dd2ef46e5464484fbdf119393afa58.tar.gz);
  pkgs_with_moz = import <nixpkgs> {
    overlays = [ moz_overlay ];
  };
  pkgs' = pkgs;
in

let
  pkgs = if pkgs' != null then pkgs' else pkgs_with_moz;
  rust = (pkgs.rustChannelOf {
    date = "2021-10-14";
    channel = "nightly";
  }).rust.override {
    extensions = [ "rust-src" ];
  };
  rustCargoDepsHash = "sha256-TezWQCk2wwzEy5Y9zPvSH5++o8KKTZZJ86d5zxQ/yQ4=";

  cargoLockUtils = pkgs.callPackage ../cargo-lock-utils {
    inherit pkgs;
  };

  cargoDebugHook = pkgs.callPackage ({ }:
    pkgs.makeSetupHook {
      name = "cargo-debug-hook.sh";
    } ./cargo-debug-hook.sh) {};

  rustCompilerDepsVendor = rust: sha256:
    pkgs.stdenvNoCC.mkDerivation {
      name = "rust-deps";
      version = rust.name;

      nativeBuildInputs = with pkgs; [
        curl
      ];

      buildCommand = ''
        mkdir downloads
        cd downloads

        curlVersion=$(curl -V | head -1 | cut -d' ' -f2)
        curl=(
           curl
           --location
           --max-redir 20
           --retry 3
           --user-agent "curl/$curlVersion Nixpkgs/$nixpkgsVersion"
           --insecure
        )

        ${cargoLockUtils}/bin/list-cargo-lock ${rust}/lib/rustlib/src/rust/Cargo.lock | while read url name checksum; do
          "''${curl[@]}" "$url" | tar xz
          (
             cd $name;
             ${cargoLockUtils}/bin/compute-checksum "$(pwd)" "$checksum" > .cargo-checksum.json
          )
        done

        mkdir $out
        cp -r * $out/
        cp ${rust}/lib/rustlib/src/rust/Cargo.lock $out/
      '';

      outputHashAlgo = "sha256";
      outputHash = sha256;
      outputHashMode = "recursive";
    };
  rustCompilerDeps = rustCompilerDepsVendor rust rustCargoDepsHash;

  mergeCargo = projectCargoLock: rustCargoLock:
    pkgs.stdenvNoCC.mkDerivation {
      name = "merged-cargo-vendors";

      buildCommand = ''
        mkdir -p $out
        find ${projectCargoLock} -mindepth 1 -maxdepth 1 -type d \
            -exec ln -sf {} $out/ \;
        find ${rustCargoLock} -mindepth 1 -maxdepth 1 -type d \
            -exec ln -sf {} $out/ \;
        cp ${projectCargoLock}/Cargo.lock $out/
      '';
    };
in

with pkgs;
stdenv.mkDerivation rec {
  name = "nested-partition-loader";
  version = "0.0.0";

  src = nix-gitignore.gitignoreSource [] ./.;

  cargoProjectDeps = rustPlatform.fetchCargoTarball {
    inherit src;
    name = "${name}-${version}";
    sha256 = "sha256-9F3XiynDfgCaqZ1HRLz6CvNqcDAdDXwJTJQtw6KDjQc=";
  };
  cargoProjectDepsUnpacked = stdenvNoCC.mkDerivation {
    name = cargoProjectDeps.name + "-unpacked";
    buildCommand = ''
      tar xf ${cargoProjectDeps}
      mv *.tar.gz $out
    '';
  };
  cargoDeps = mergeCargo cargoProjectDepsUnpacked rustCompilerDeps;

  nativeBuildInputs = [
    rust
  ] ++ (with rustPlatform; [
    cargoSetupHook
    #cargoDebugHook
  ]);

  buildProfile = "release";
  target = "x86_64-unknown-uefi";
  buildPhase = ''
    runHook preBuild

    cargo build -j $NIX_BUILD_CORES \
      -Zbuild-std=core,compiler_builtins,alloc \
      -Zbuild-std-features=compiler-builtins-mem \
      --target ${target} \
      --frozen \
      --${buildProfile}

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp "target/${target}/${buildProfile}/${name}.efi" $out/bin
  '';

  meta = with lib; {
    description = "EFI loader into nested partitions";
    license = licenses.unlicense;
    maintainers = [ maintainers.baloo ];
  };

  impureEnvVars = lib.fetchers.proxyImpureEnvVars;
}
