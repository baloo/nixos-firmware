{ rustPlatform
, nix-gitignore
, llvmPackages
, linuxHeaders
}:

rustPlatform.buildRustPackage rec {
  pname = "partuuidx";
  version = "0.0.0";

  src = nix-gitignore.gitignoreSource [] ./.;

  LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";
  BINDGEN_EXTRA_CLANG_ARGS = "-I${linuxHeaders}/include";

  cargoHash = "sha256-ClushISa8L4V1DYDOKs8NDfWJGYV7gdikugL3zArkuU=";
  cargoDepsName = pname;
}
