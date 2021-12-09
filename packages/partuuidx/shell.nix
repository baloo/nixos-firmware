with import <nixpkgs> {};

mkShell {
  buildInputs = with pkgs; [
    cargo
    rustc
    rustfmt
  ];
  
  LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";

  # build on ubuntu/debian
  BINDGEN_EXTRA_CLANG_ARGS="-I/usr/include -I/usr/include/x86_64-linux-gnu/";
}
