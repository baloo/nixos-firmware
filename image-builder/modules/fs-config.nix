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
     };
   };
 };
}
