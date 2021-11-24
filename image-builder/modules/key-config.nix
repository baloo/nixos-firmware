{ key
, volumeLabel
, merkleTreeLabel
, integrityLabel
}:

{ pkgs
, ...
}: {
 config = {
   boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.cryptsetup}/bin/veritysetup
   '';

   #boot.initrd.postDeviceCommands = ''
   #  find /dev
   #'';

   boot.initrd.preLVMCommands = ''
     set -x
     # TODO: kpartx does not create the /dev/disk/by-partuuid because it only exposes the partitions as dm-linear
     #       now, that sucks because here we'd like to rely on partition guid to mount them.
     for o in $(cat /proc/cmdline); do
         case $o in
             firmware.loaded=*)
                 # kpartx will dm-linear the disk and create dm-* devices from it.
                 ${pkgs.multipath-tools}/bin/kpartx -a -r -v -g $(readlink -f "/dev/disk/by-partuuid/''${o#firmware.loaded=}")
                 dmsetup status
                 ;;
         esac
     done
     #veritysetup --root-hash-file=${key} create "${integrityLabel}" /dev/disk/by-partlabel/${volumeLabel} /dev/disk/by-partlabel/${merkleTreeLabel}
     veritysetup --root-hash-file=${key} create "${integrityLabel}" /dev/disk/by-id/dm-name-vda2p2 /dev/disk/by-id/dm-name-vda2p3
     set +x
   '';
   boot.initrd.postMountCommands = ''
     mount -t tmpfs none /mnt-root/etc
     mount -t tmpfs none /mnt-root/var
     mount -t tmpfs none /mnt-root/nix/var
     mount -t tmpfs none /mnt-root/usr/bin
     mount -t tmpfs none /mnt-root/bin
     mount -t tmpfs none /mnt-root/tmp

     mkdir -p /mnt-root/nix/var/nix/gcroots/
   '';
 };
}

