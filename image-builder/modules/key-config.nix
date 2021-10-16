{ key
, volumeLabel
, merkleTreeLabel
}:

{ pkgs
, ...
}: {
 config = {
   boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.cryptsetup}/bin/veritysetup
   '';

   boot.initrd.preLVMCommands = ''
     veritysetup --root-hash-file=${key} create vroot /dev/disk/by-partlabel/${volumeLabel} /dev/disk/by-partlabel/${merkleTreeLabel}
   '';
   boot.initrd.postMountCommands = ''
     mount -t tmpfs none /mnt-root/etc
     mount -t tmpfs none /mnt-root/var
     mount -t tmpfs none /mnt-root/nix/var
     mount -t tmpfs none /mnt-root/usr/bin
     mount -t tmpfs none /mnt-root/bin
     mount -t tmpfs none /mnt-root/tmp
   '';
 };
}

