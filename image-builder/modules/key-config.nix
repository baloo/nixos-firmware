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
     set -x
     veritysetup --root-hash-file=${key} create vroot /dev/disk/by-label/volumeLabel /dev/disk/by-label/merkleTreeLabel
     ls -la /dev/
   '';
 };
}

