
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
    innerGuid = {
      btree = "cf102aaf-ef46-48bc-be47-54a3680da159";
      data = "00299141-a24e-4f28-b042-414fcf8349ad";
      kernel = "58628ff9-750a-4378-873b-6aba3e9d8c62";
    };
    outerGuid = {
      esp = "12fd7b40-2a42-495e-aa3b-f1c9c3c3ad05";
      firmwareA = "ed38b728-db62-4127-8962-9ef6ba2c78b0";
      firmwareB = "1902c57d-d578-4ecb-8294-40859c937d4e";
    };
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
