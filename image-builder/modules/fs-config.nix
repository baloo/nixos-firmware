{ volumeLabel
}:

{ ...
}: {
 config = {
   boot.loader.grub.enable = false;
   # todo: move that
   boot.initrd.kernelModules = [
      "dm_verity"
   ];
   fileSystems = {
     "/" = {
       device = "/dev/disk/by-label/${volumeLabel}";
       fsType = "ext4";
       options = [ "ro" ];
     };
   };
 };
}
