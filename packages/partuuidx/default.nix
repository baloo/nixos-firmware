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

  cargoHash = "sha256-caS9Yq/27rwGnK7I807jnb6pB7IC55iqvBUJPIBtfao=";
  cargoDepsName = pname;
}
