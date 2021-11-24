{ ...
}:

{ lib
, ...
}: {
  config = {
    system.activationScripts.nix = lib.mkForce "";

    nix.readOnlyStore = true;

    # dont run fsck
    boot.initrd.checkJournalingFS = false;
  };
}

