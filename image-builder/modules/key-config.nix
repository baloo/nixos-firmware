{ key
, volumeLabel
, merkleTreeLabel
, integrityLabel
, partuuidx
, innerGuid
}:

{ pkgs
, ...
}: {
 config = {
   boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.cryptsetup}/bin/veritysetup
   '';

   boot.initrd.preLVMCommands = ''
     set -x
     for o in $(cat /proc/cmdline); do
         case $o in
             firmware.loaded=*)
                 outsidePartition=$(readlink -f "/dev/disk/by-partuuid/''${o#firmware.loaded=}")
                 ${partuuidx}/bin/partuuidx -d $outsidePartition
                 # wait for udev to generate the /dev/disk/by-id/dm-uuid-*
                 udevadm settle
                 ;;
         esac
     done
     md5sum ${key}
     md5sum /dev/disk/by-partuuid/${innerGuid.data} /dev/disk/by-partuuid/${innerGuid.mtree}
     [ -e /dev/disk/by-id/dm-uuid-${innerGuid.data} ] && veritysetup --root-hash-file=${key} create "${integrityLabel}" /dev/disk/by-id/dm-uuid-${innerGuid.data} /dev/disk/by-id/dm-uuid-${innerGuid.mtree}
     [ -e /dev/disk/by-partuuid/${innerGuid.data} ] && veritysetup --root-hash-file=${key} create "${integrityLabel}" /dev/disk/by-partuuid/${innerGuid.data} /dev/disk/by-partuuid/${innerGuid.mtree}
     find /dev/disk
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

