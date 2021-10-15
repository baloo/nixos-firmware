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
     # Cryptsetup locking directory
     # mkdir -p /run/cryptsetup
     ls -la /dev/
     ls -la /dev/disk
     find /dev/disk -exec ls -la {} \;
     head -c 100 /dev/sr0 | xxd
     set -x
     veritysetup --root-hash-file=${key} create vroot /dev/disk/by-partlabel/${volumeLabel} /dev/disk/by-partlabel/${merkleTreeLabel}
     ls -la /dev/
     find /dev/disk -exec ls -la {} \;
   '';
 };
}

