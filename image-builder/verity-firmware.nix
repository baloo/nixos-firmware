{ configuration, lib, pkgs, ...}:

with lib;

let
  integrityLabel = "firmware";
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
        inherit key volumeLabel merkleTreeLabel integrityLabel;
      })
    ];
  });

  # Compute a unique name from the configuration itself
  configName = (eval {}).config.system.build.toplevel.drvPath;
  # this goes in partition labels, partition labels are 36 chars max.
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
    '';
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

      align() {
        x=$1
        a=$2
        mask=$((a - 1))
        echo $((($x + $mask) & ~$mask))
      }

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
        mklabel GPT \
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
  configWithKey = (eval {
    inherit volumeLabel merkleTreeLabel;
    key = diskImage.key;
  }).config;
in {
  disk-image = diskImage.out;
  main-config = configWithKey.system.build.toplevel;
  inner-config = config.system.build.toplevel;
}
