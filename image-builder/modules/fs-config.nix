{ integrityLabel
}:

{ ...
}: {
 config = {
   boot.loader.grub.enable = false;

   fileSystems = {
     "/" = {
       device = "/dev/disk/by-id/dm-name-${integrityLabel}";
       fsType = "ext4";
       options = [ "ro" ];
     };
   };
 };
}
