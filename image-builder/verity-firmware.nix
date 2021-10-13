{ configuration, lib, pkgs, ...}:

with lib;

let
  volumeLabel = "firmware";
  merkleTreeLabel = "merkle-tree";
  eval = { key ? null}: (import <nixpkgs/nixos/lib/eval-config.nix> {
    modules = [ configuration ];
    extraModules = [
      (import ./modules/fs-config.nix {
        inherit volumeLabel;
      })
    ] ++ optionals (key != null) [
      (import ./modules/key-config.nix {
        inherit key volumeLabel merkleTreeLabel;
      })
    ];
  });
  config = (eval {}).config;
  rootfsImage = pkgs.callPackage <nixpkgs/nixos/lib/make-ext4-fs.nix> {
    compressImage = false;
    storePaths = [ config.system.build.toplevel ];
    inherit volumeLabel;
  };
  diskImage = pkgs.stdenv.mkDerivation {
    name = "dm-verity-image";

    nativeBuildInputs = with pkgs; [
      parted
      cryptsetup
    ];

    outputs = [ "out" "key" ];

    buildCommand = ''
      truncate --size=0 merkle-tree key
      veritysetup format --root-hash-file=key ${rootfsImage} merkle-tree

      cp key $key

      ls -la ${rootfsImage}

      align() {
        x=$1
        a=$2
        mask=$((a - 1))
        echo $((($x + $mask) & ~$mask))
      }
      set -x

      imageSize=$(wc --bytes ${rootfsImage} | cut -f 1 -d ' ')
      imageSizePageAligned=$(align $imageSize 4096)
      mTreeSize=$(wc --bytes merkle-tree | cut -f 1 -d ' ')
      mTreeSizePageAligned=$(align $mTreeSize 4096)

      # In GPT the first usable sector is LBA 34, but it's not 4k page aligned. This would be LBA 36
      gptHeaderSize=$(align $((34 * 512)) 4096)

      # Because GPT uses a head and tail header (tail is a backup iirc), we have to provide that twice.
      # Also include a 4096 gap in between partitions
      truncate --size=$((imageSizePageAligned + mTreeSizePageAligned + (gptHeaderSize * 2) + 4096)) image

      # parted aligns on physical block, but because we're building in a ramfs this is wrong.
      # Physical block *will* be at most 4k, no matter nvme or rotational drive (4kn or 512n)
      parted --align=none ./image \
        mktable gpt \
        unit B \
        mkpart primary ext4 $gptHeaderSize $((gptHeaderSize + imageSizePageAligned)) \
        name 1 ${volumeLabel} \
        mkpart primary ext4 $((gptHeaderSize + imageSizePageAligned + 4096)) $((gptHeaderSize + imageSizePageAligned + mTreeSizePageAligned + 4096)) \
        name 2 ${merkleTreeLabel} \
        print

      dd if=${rootfsImage} of=image seek=$((gptHeaderSize / 4096)) bs=4096 conv=notrunc
      dd if=merkle-tree of=image seek=$(( (gptHeaderSize + imageSizePageAligned + 4096) / 4096)) bs=4096 conv=notrunc
      cp image $out
    '';
  };
  #configWithKey = (eval {}).system.build.toplevel;
  #configWithKey = (eval {}).config;
  configWithKey = (eval {
    key = diskImage.key;
  }).config;
#in configWithKey
#in diskImage.key
in configWithKey.system.build.toplevel
