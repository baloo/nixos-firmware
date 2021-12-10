
let
  pkgs = import <nixpkgs> {};
  configuration = { pkgs, ... }: {
    networking.hostName = "demo";
    services.getty.autologinUser = "root";

    boot.kernelPackages = pkgs.linuxPackages_latest;

    boot.initrd.verbose = true;
    boot.initrd.kernelModules = [
      "virtio" "virtio_pci" "virtio_ring" "virtio_net" "virtio_blk"
    ];

    # dont run fsck
    boot.initrd.checkJournalingFS = false;

    environment.systemPackages = with pkgs; [
      tpm2-tools
    ];
  };
  guids = {
    innerGuid = {
      mtree = "cf102aaf-ef46-48bc-be47-54a3680da159";
      data = "00299141-a24e-4f28-b042-414fcf8349ad";
      kernel = "58628ff9-750a-4378-873b-6aba3e9d8c62";
    };
    outerGuid = {
      esp = "12fd7b40-2a42-495e-aa3b-f1c9c3c3ad05";
      firmwareA = "ed38b728-db62-4127-8962-9ef6ba2c78b0";
      firmwareB = "1902c57d-d578-4ecb-8294-40859c937d4e";
    };
  };
  system-image = import image-builder/verity-firmware.nix {
    inherit pkgs configuration;
    inherit (pkgs) lib;
    inherit (guids) innerGuid outerGuid;
  };
in pkgs.writeShellScript "run.sh" ''
  SWTPM=$(mktemp -t -d swtpm.XXXXX)
  set -x
  mkdir "''${SWTPM}/state"
  ${pkgs.swtpm}/bin/swtpm socket \
    --tpmstate dir="''${SWTPM}/state" \
    --ctrl type=unixio,path="''${SWTPM}/sock" \
    --log level=20 \
    --tpm2 --flags not-need-init \
    --daemon --pid file="''${SWTPM}/pid"
  sleep 1 # wait for swtpm to initialize

  case $1 in
    debug-update)
      DISK="-drive file=${system-image.update-disk-image},if=none,read-only=on,id=virtio-disk0,format=raw"
      KERNEL="-kernel ${system-image.main-config}/kernel"
      KERNEL="$KERNEL -initrd ${system-image.main-config}/initrd"
      KERNEL="$KERNEL -append console=ttyS0"
      ;;
    debug-outer)
      DISK="-drive file=${system-image.disk-image},if=none,read-only=on,id=virtio-disk0,format=raw"
      KERNEL="-kernel ${system-image.main-config}/kernel"
      KERNEL="$KERNEL -initrd ${system-image.main-config}/initrd"
      KERNEL="$KERNEL -append console=ttyS0\ firmware.loaded=${guids.outerGuid.firmwareA}"
      ;;
    *)
      DISK="-drive file=${system-image.disk-image},if=none,read-only=on,id=virtio-disk0,format=raw"
      KERNEL="-kernel ${pkgs.OVMFFull}/X64/Shell.efi"
      ;;
  esac
  ${pkgs.qemu}/bin/qemu-system-x86_64 \
    -nodefaults \
    -enable-kvm -m 4G \
    -cpu max \
    -serial mon:stdio -nographic \
    \
    -bios ${pkgs.OVMFFull.fd}/FV/OVMF_CODE.fd \
    \
    -mon chardev=con0,mode=readline \
    -chardev socket,id=con0,path=./console.pipe,server=on,wait=off \
    \
    $DISK \
    -device virtio-blk-pci,drive=virtio-disk0,id=disk0,scsi=off \
    \
    -chardev socket,id=chrtpm,path="''${SWTPM}/sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    \
    $KERNEL
    #-kernel ${pkgs.OVMFFull}/X64/Shell.efi
    #-debugcon file:debug.log -global isa-debugcon.iobase=0x402 \

  rm -rf "''${SWTPM}"
''
