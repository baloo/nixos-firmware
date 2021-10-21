let
  pkgs = import <nixpkgs> {};
in
pkgs.mkShell {
  buildInputs = (import ./default.nix {}).buildInputs;
  nativeBuildInputs = (import ./default.nix {}).nativeBuildInputs;
}
