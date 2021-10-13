
let
  pkgs = import <nixpkgs> {};
  configuration = { pkgs, ... }: {
    networking.hostName = "demo";
  };
  builder = import image-builder/verity-firmware.nix {
    inherit pkgs configuration;
    inherit (pkgs) lib;
  };
in builder
  
  
