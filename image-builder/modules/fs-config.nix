{ volumeLabel
}:

{ ...
}: {
 config = {
   boot.loader.grub.enable = false;

   fileSystems = {
     "/" = {
       device = "/dev/disk/by-label/${volumeLabel}";
       fsType = "ext4";
       options = [ "ro" ];
     };
   };

   # todo: move that
   boot.initrd.kernelModules = [
      "dm_verity"
   ];
   nix.readOnlyStore = true;
 };
}
