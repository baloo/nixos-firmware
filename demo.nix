
let
  pkgs = import <nixpkgs> {};
  configuration = { pkgs, ... }: {
    networking.hostName = "demo";
    services.getty.autologinUser = "root";

    boot.initrd.verbose = true;
    boot.initrd.kernelModules = [
      "virtio" "virtio_pci" "virtio_ring" "virtio_net" "virtio_blk"
    ];

    # dont run fsck
    boot.initrd.checkJournalingFS = false;
  };
  system-image = import image-builder/verity-firmware.nix {
    inherit pkgs configuration;
    inherit (pkgs) lib;
  };
in pkgs.writeShellScript "run.sh" ''
  ${pkgs.qemu}/bin/qemu-system-x86_64 \
    -nodefaults \
    -enable-kvm -m 4G \
    -cpu max \
    -serial mon:stdio -nographic \
    \
    -mon chardev=con0,mode=readline \
    -chardev socket,id=con0,path=./console.pipe,server,nowait \
    \
    -drive file=${system-image.disk-image},if=none,read-only=on,id=virtio-disk0,format=raw \
    -device virtio-blk-pci,drive=virtio-disk0,id=disk0,scsi=off \
    \
    -kernel ${system-image.main-config}/kernel \
    -initrd ${system-image.main-config}/initrd \
    -append "console=ttyS0 root=LABEL=firmware init=${system-image.inner-config}/init"
''
