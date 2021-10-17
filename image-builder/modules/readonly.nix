{ ...
}:

{ lib
, ...
}: {
 config = {
   system.activationScripts.nix = lib.mkForce "";

   nix.readOnlyStore = true;
 };
}

