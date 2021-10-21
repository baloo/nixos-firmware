with import <nixpkgs> {};

let
  disk-image = stdenvNoCC.mkDerivation {
    name = "image";

    nativeBuildInputs = [
      parted
    ];

    buildCommand = ''
      align() {
        x=$1
        a=$2
        mask=$((a - 1))
        echo $((($x + $mask) & ~$mask))
      }

      espSize=$((2 * 1024 * 1024))
      imageSize=$((2 * 1024 * 1024))

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
        name 1 entry \
        set 1 esp on \
        mkpart primary ext4 $imageAOffset $((imageAOffset + imageSize - 1)) \
        name 2 firmware-A \
        mkpart primary ext4 $imageBOffset $((imageBOffset + imageSize - 1)) \
        name 3 firmware-B \
        print

      cp image $out
    '';
  };
in writeShellScript "run.sh" ''
  if [ "$1" = "shell" ]; then
     arg="-kernel ${OVMFFull}/X64/Shell.efi"
  else
     arg="-kernel target/x86_64-unknown-uefi/debug/nested-partition-loader.efi -append boot-index=42"
  fi

  ${qemu}/bin/qemu-system-x86_64 \
    -nodefaults \
    \
    -bios ${OVMFFull.fd}/FV/OVMF_CODE.fd \
    \
    -enable-kvm -m 4G \
    -cpu max \
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
