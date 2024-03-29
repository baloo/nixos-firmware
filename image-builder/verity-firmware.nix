{ configuration
, lib
, pkgs
, innerGuid
, outerGuid
, ...}:

with lib;

let
  moz_overlay = import (builtins.fetchTarball https://codeload.github.com/mozilla/nixpkgs-mozilla/tar.gz/0510159);
  # Import nixpkgs twice? meh :(
  pkgs' = import <nixpkgs> {
    overlays = [ moz_overlay ];
  };
in
let
  integrityLabel = "firmware";
  kernelLabel = "kernel";

  nested-partition-loader = import ../packages/nested-partition-loader {
    #inherit pkgs;
  };

  pecoff-checksum = import ../packages/pecoff-checksum {
    inherit (pkgs) python3Packages openssl lib stdenv;
  };

  partuuidx = pkgs.callPackage ../packages/partuuidx {};

  eval = { key ? null
         , volumeLabel ? "dummy"
         , merkleTreeLabel ? "dummy"
  }: (import <nixpkgs/nixos/lib/eval-config.nix> {
    modules = [ configuration ];
    extraModules = [
      (import ./modules/fs-config.nix {
        inherit integrityLabel;
      })
      (import ./modules/readonly.nix {
      })
      (import ./modules/dm-verity.nix {
      })
    ] ++ optionals (key != null) [
      (import ./modules/key-config.nix {
        inherit key volumeLabel merkleTreeLabel integrityLabel partuuidx innerGuid;
      })
    ];
  });

  # Compute a unique name from the configuration itself
  configName = (eval {}).config.system.build.toplevel.drvPath;
  # this goes in partition labels, partition labels are 36 chars max (36 UTF-16LE).
  # sha1 hexencoded would give us 40, we're using md5 instead, which yield 32chars.
  volumeLabel = builtins.hashString "md5" (configName + "volume");
  merkleTreeLabel = builtins.hashString "md5" (configName + "merkle-tree");

  config = (eval {
    inherit volumeLabel merkleTreeLabel;
  }).config;

  rootfsImage = pkgs.callPackage <nixpkgs/nixos/lib/make-ext4-fs.nix> {
    compressImage = false;
    storePaths = [ config.system.build.toplevel ];
    inherit volumeLabel;
    populateImageCommands = ''
      mkdir -m 0755 files/proc files/sys files/dev files/run files/var files/etc files/usr files/bin files/nix files/nix/var files/home files/usr/bin
      mkdir -m 01777 files/tmp
      mkdir -m 0700 files/root
      # We cant pass init=/nix/store/.../init to the kernel parameters, so we'll just symlink from the disk
      ln -s ${config.system.build.toplevel}/init files/init
    '';
  };
  merkleTree = pkgs.stdenv.mkDerivation {
    name = "merkle-tree";
    nativeBuildInputs = with pkgs; [
      cryptsetup
    ];

    outputs = [ "out" "key" ];

    buildCommand = ''
      truncate --size=0 merkle-tree key
      veritysetup format --root-hash-file=key ${rootfsImage} merkle-tree
      set -e
      veritysetup verify --root-hash-file=key ${rootfsImage} merkle-tree
      md5sum key merkle-tree ${rootfsImage}

      cp key $key
      cp merkle-tree $out
    '';
  };

  configWithKey = (eval {
    inherit volumeLabel merkleTreeLabel;
    key = merkleTree.key;
  }).config;

  efiKernelImageMake' = import ../packages/efi-kernel-make {
    inherit pkgs pecoff-checksum;
  };
  efiKernelImageMake = config:
    efiKernelImageMake' {
      kernel = "${config.boot.kernelPackages.kernel}/" + "${config.system.boot.loader.kernelFile}";
      initramfs = "${config.system.build.initialRamdisk}/" + "${config.system.boot.loader.initrdFile}";
      params = config.boot.kernelParams;
      toplevel = config.system.build.toplevel;
    };

  bootentries = let
    bootentry = { fname, desc, index }: pkgs.writeText fname ''
      title ${desc}
      efi /nested-partition-loader.efi
      options boot-index=${index}
    '';

  in {
    loader-conf = pkgs.writeText "loader.conf" ''
      default firmwareA.conf
      timeout 2
      editor no
      console-mode max
    '';
    firmwareA = bootentry {
      fname = "firmwareA.conf";
      desc = "firmware A";
      index = outerGuid.firmwareA;
    };
    firmwareB = bootentry {
      fname = "firmwareB.conf";
      desc = "firmware B";
      index = outerGuid.firmwareB;
    };
  };

  espPartitionImage = pkgs.stdenvNoCC.mkDerivation {
    name = "nested-partition-loader-diskimage";

    nativeBuildInputs = with pkgs; [
      lkl
      util-linux
      dosfstools
    ];

    buildCommand = ''
      set -eu

      imageSize=$((20 * 1024 * 1024))

      truncate -s $imageSize esp
      mkfs.vfat esp
      mkdir root \
            root/EFI \
            root/EFI/BOOT \
            root/loader \
            root/loader/entries

      echo "\EFI\BOOT\BOOTX64.EFI" > root/startup.nsh
      cp ${bootentries.loader-conf}                                 root/loader/loader.conf
      cp ${bootentries.firmwareA}                                   root/loader/entries/firmwareA.conf
      cp ${bootentries.firmwareB}                                   root/loader/entries/firmwareB.conf
      cp ${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi   root/EFI/BOOT/BOOTX64.EFI
      cp ${nested-partition-loader}/bin/nested-partition-loader.efi root/
      cptofs -i esp -t vfat root/* /

      #cptofs -i esp -t vfat ${nested-partition-loader}/bin/nested-partition-loader.efi \

      cp esp $out
    '';
  };

  updateDiskImage = pkgs.stdenvNoCC.mkDerivation {
    name = "dm-verity-image";

    nativeBuildInputs = with pkgs; [
      parted
      util-linux
      gptfdisk
      python3Minimal
    ];

    buildCommand = ''
      set -eu

      align() {
        x=$1
        a=$2
        mask=$((a - 1))
        echo $((($x + $mask) & ~$mask))
      }
      set -x

      kernel="${efiKernelImageMake configWithKey}/linux.efi"
      kernelSizeOrig=$(wc --bytes $kernel | cut -f 1 -d ' ')
      # Store metadata as header
      kernelSize=$((kernelSizeOrig + 4096))
      kernelSizePageAligned=$(align $kernelSize 4096)
      imageSize=$(wc --bytes ${rootfsImage} | cut -f 1 -d ' ')
      imageSizePageAligned=$(align $imageSize 4096)
      mTreeSize=$(wc --bytes ${merkleTree} | cut -f 1 -d ' ')
      mTreeSizePageAligned=$(align $mTreeSize 4096)

      # In GPT the first usable sector is LBA 34, but it's not 4k page aligned. This would be LBA 36
      gptHeaderSize=$(align $((34 * 512)) 4096)

      kernelMetaOffset=$((gptHeaderSize))
      kernelOffset=$((kernelMetaOffset + 4096))
      imageOffset=$((kernelMetaOffset + kernelSizePageAligned))
      mTreeOffset=$((imageOffset + imageSizePageAligned))

      # Because GPT uses a head and tail header (tail is a backup iirc), we have to provide that twice.
      truncate --size=$((mTreeOffset + mTreeSizePageAligned + (gptHeaderSize * 2))) image

      # parted aligns on physical block, but because we're building in a ramfs this is wrong.
      # Physical block *will* be at most 4k, no matter nvme or rotational drive (4kn or 512n)
      parted --align=none ./image \
        mklabel GPT \
        unit B \
        mkpart primary linux-swap $kernelMetaOffset $((kernelMetaOffset + kernelSizePageAligned - 1)) \
        name 1 ${kernelLabel} \
        mkpart primary ext4 $imageOffset $((imageOffset + imageSizePageAligned - 1)) \
        name 2 ${volumeLabel} \
        mkpart primary ext4 $mTreeOffset $((mTreeOffset + mTreeSizePageAligned - 1)) \
        name 3 ${merkleTreeLabel} \
        print

      sgdisk \
          --partition-guid=1:${innerGuid.kernel} \
          --partition-guid=2:${innerGuid.data} \
          --partition-guid=3:${innerGuid.mtree} \
          ./image

      # write kernel size in the sector before the kernel
      set -x
      python -c "import struct; import sys; sys.stdout.buffer.write(struct.pack('<i', int(sys.argv[1])))" $kernelSizeOrig > meta
      dd if=meta of=image seek=$((kernelMetaOffset / 4096)) bs=4096 conv=notrunc
      dd if=$kernel of=image seek=$((kernelOffset / 4096)) bs=4096 conv=notrunc
      dd if=${rootfsImage} of=image seek=$((imageOffset / 4096)) bs=4096 conv=notrunc
      dd if=${merkleTree}  of=image seek=$((mTreeOffset / 4096)) bs=4096 conv=notrunc
      set +x
      cp image $out
    '';
  };
  diskImage = pkgs.stdenv.mkDerivation {
    name = "flip-flop-full-image";

    nativeBuildInputs = with pkgs; [
      parted
      gptfdisk
    ];

    buildCommand = ''
      set -eu

      align() {
        x=$1
        a=$2
        mask=$((a - 1))
        echo $((($x + $mask) & ~$mask))
      }

      espSize=$((2 * 1024 * 1024))
      imageSize=$((2 * 1024 * 1024 * 1024)) # 10GB

      # In GPT the first usable sector is LBA 34, but it's not 4k page aligned. This would be LBA 36
      gptHeaderSize=$(align $((34 * 512)) 4096)

      # Because GPT uses a head and tail header (tail is a backup iirc), we have to provide that twice.
      # Also include a 4096 gap in between partitions
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
        name 1 boot \
        set 1 esp on \
        mkpart primary ext4 $imageAOffset $((imageAOffset + imageSize - 1)) \
        name 2 firmware-A \
        mkpart primary ext4 $imageBOffset $((imageBOffset + imageSize - 1)) \
        name 3 firmware-B \
        print

      sgdisk \
          --partition-guid=1:${outerGuid.esp} \
          --partition-guid=2:${outerGuid.firmwareA} \
          --partition-guid=3:${outerGuid.firmwareB} \
          ./image

      dd if=${espPartitionImage} of=image seek=$((espOffset / 4096)) bs=4096 conv=notrunc
      dd if=${updateDiskImage} of=image seek=$((imageAOffset / 4096)) bs=4096 conv=notrunc

      cp image $out
    '';
  };
in {
  update-disk-image = updateDiskImage;
  disk-image = diskImage;
  main-config = configWithKey.system.build.toplevel;
  inner-config = config.system.build.toplevel;
}
