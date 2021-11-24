with import <nixpkgs> {};

let
  pecoff-checksum = import ../pecoff-checksum {
    inherit (pkgs) python3Packages openssl lib stdenv;
  };

  efiKernelImageMake' = import ../efi-kernel-make {
    inherit pkgs pecoff-checksum;
  };

  initrd = stdenvNoCC.mkDerivation { 
    name = "emptyinitrd";
    buildCommand = ''
      mkdir -p $out
      truncate -s 0 $out/initrd
    '';
  };

  kernel = efiKernelImageMake' {
    kernel = "${pkgs.linuxPackages.kernel}/bzImage";
    initramfs = "${initrd}/initrd";
    params = "panic=1";
    toplevel = "foo";
  };

  inner-disk-image = stdenvNoCC.mkDerivation {
    name = "image";

    nativeBuildInputs = [
      parted
      lkl
      gptfdisk
      python3Minimal
    ];

    buildCommand = ''
      align() {
        x=$1
        a=$2
        mask=$((a - 1))
        echo $((($x + $mask) & ~$mask))
      }

      kernelSizeOrig=$(wc --bytes ${kernel}/linux.efi | cut -f 1 -d ' ')
      # Get head space for storing its size
      kernelSize=$((kernelSizeOrig + 4096))
      kernelSize=$(align kernelSize 4096)
      imageSize=$((1 * 1024 * 1024))

      # In GPT the first usable sector is LBA 34, but it's not 4k page aligned. This would be LBA 36
      gptHeaderSize=$(align $((34 * 512)) 4096)

      truncate --size=$((imageSize * 2 + kernelSize + (gptHeaderSize * 2))) image

      kernelMetaOffset=$((gptHeaderSize))
      kernelOffset=$((kernelMetaOffset + 4096))
      imageOffset=$((kernelOffset + kernelSize - 4096))
      mtreeOffset=$((imageOffset + imageSize))

      # parted aligns on physical block, but because we're building in a ramfs this is wrong.
      # Physical block *will* be at most 4k, no matter nvme or rotational drive (4kn or 512n)
      parted --align=none ./image \
        mklabel GPT \
        unit B \
        mkpart primary fat32 $kernelMetaOffset $((kernelMetaOffset + kernelSize - 1)) \
        name 1 kernel \
        mkpart primary ext4 $imageOffset $((imageOffset + imageSize - 1)) \
        name 2 disk \
        mkpart primary ext4 $mtreeOffset $((mtreeOffset + imageSize - 1)) \
        name 3 mtree \
        print

      sgdisk \
          --partition-guid=1:5c513513-e1b6-4fb1-aee8-b12da81551f3 \
          --partition-guid=2:5c513513-e1b6-4fb1-aee8-b12da81551f4 \
          --partition-guid=3:5c513513-e1b6-4fb1-aee8-b12da81551f5 \
          ./image

      dd if=${kernel}/linux.efi of=image seek=$((kernelOffset / 4096)) bs=4096 conv=notrunc
      # write kernel size in the sector before the kernel
      python -c "import struct; import sys; sys.stdout.buffer.write(struct.pack('<i', int(sys.argv[1])))" $kernelSizeOrig > meta
      dd if=meta of=image seek=$((kernelMetaOffset / 4096)) bs=4096 conv=notrunc

      cp image $out
    '';
  };
  disk-image = stdenvNoCC.mkDerivation {
    name = "image";

    nativeBuildInputs = [
      parted
      lkl
      gptfdisk
      dosfstools
    ];

    buildCommand = ''
      align() {
        x=$1
        a=$2
        mask=$((a - 1))
        echo $((($x + $mask) & ~$mask))
      }

      espSize=$((2 * 1024 * 1024))
      imageSize=$((20 * 1024 * 1024))

      # In GPT the first usable sector is LBA 34, but it's not 4k page aligned. This would be LBA 36
      gptHeaderSize=$(align $((34 * 512)) 4096)

      truncate --size=$((imageSize * 2 + (gptHeaderSize * 2) + espSize)) image

      espOffset=$gptHeaderSize
      imageAOffset=$((espOffset + espSize))
      imageBOffset=$((imageAOffset + imageSize))

      # parted aligns on physical block, but because we're building in a ramfs this is wrong.
      # Physical block *will* be at most 4k, no matter nvme or rotational drive (4kn or 512n)
      parted --align=none ./image \
        mklabel GPT \
        unit B \
        mkpart primary fat32 $espOffset $((espOffset + espSize-1)) \
        name 1 bootloader \
        set 1 esp on \
        mkpart primary ext4 $imageAOffset $((imageAOffset + imageSize - 1)) \
        name 2 firmware-A \
        mkpart primary ext4 $imageBOffset $((imageBOffset + imageSize - 1)) \
        name 3 firmware-B \
        print

      sgdisk \
          --partition-guid=1:6d70952f-ee84-45eb-b195-94ec948856b0 \
          --partition-guid=2:6d70952f-ee84-45eb-b195-94ec948856b1 \
          --partition-guid=3:6d70952f-ee84-45eb-b195-94ec948856b2 \
          ./image

      truncate -s $imageSize esp
      mkfs.vfat esp
      cptofs -i esp -t vfat ${kernel}/linux.efi /

      dd if=esp of=image seek=$((espOffset / 4096)) bs=4096 conv=notrunc
      dd if=${inner-disk-image} of=image seek=$((imageAOffset / 4096)) bs=4096 conv=notrunc

      cp image $out
    '';
  };
in writeShellScript "run.sh" ''
  set -x
  if [ "$1" = "kernel" ]; then
     arg="-kernel ${kernel}/linux.efi"
  elif [ "$1" = "shell" ]; then
     arg="-kernel ${OVMFFull}/X64/Shell.efi"
  else
     arg="-kernel target/x86_64-unknown-uefi/debug/nested-partition-loader.efi -append boot-index=6d70952f-ee84-45eb-b195-94ec948856b1"
  fi

  ${qemu}/bin/qemu-system-x86_64 \
    -nodefaults \
    \
    -bios ${OVMFFull.fd}/FV/OVMF_CODE.fd \
    \
    -enable-kvm -m 256M \
    -no-reboot \
    -serial stdio -nographic \
    \
    -mon chardev=con0,mode=readline \
    -chardev socket,id=con0,path=./console.pipe,server,nowait \
    \
    -drive file=${disk-image},if=none,read-only=on,id=virtio-disk0,format=raw \
    -device virtio-blk-pci,drive=virtio-disk0,id=disk0,scsi=off \
    \
    $arg
''
