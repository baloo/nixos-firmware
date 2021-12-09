{ pkgs, stdenv, ... }: 


let 
  image = pkgs.stdenvNoCC.mkDerivation {
    name = "test-image";
    nativeBuildInputs = with pkgs; [
      parted
      util-linux
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
  
      kernelSize=8192
      imageSize=8192
  
      gptHeaderSize=$(align $((34 * 512)) 4096)
  
      kernelOffset=$gptHeaderSize
      imageOffset=$((kernelOffset + kernelSize))
  
      # Because GPT uses a head and tail header (tail is a backup iirc), we have to provide that twice.
      truncate --size=$((imageOffset + imageSize + (gptHeaderSize * 2))) image
  
      # parted aligns on physical block, but because we're building in a ramfs this is wrong.
      # Physical block *will* be at most 4k, no matter nvme or rotational drive (4kn or 512n)
      parted --align=none ./image \
        mklabel GPT \
        unit B \
        mkpart primary linux-swap $kernelOffset $((kernelOffset + kernelSize - 1)) \
        mkpart primary linux-swap $imageOffset $((imageOffset + imageSize - 1)) \
        print

      sgdisk \
          --partition-guid=1:dc7bb28d-1f79-4597-935a-fc8295704d9e \
          --partition-guid=2:dcc1c297-0c91-450b-8678-256e847b47ac \
          ./image

      cp image $out
    '';
  };
in {
  imports = [
    <nixpkgs/nixos/modules/profiles/minimal.nix>
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  virtualisation.memorySize = 500;

  programs.bcc.enable = true;
  environment.systemPackages = with pkgs; [
    parted
    multipath-tools
    xxd
    (writeShellScriptBin "test-partuuidx" ''
       set -x 
       losetup -f ${image}
       target/debug/partuuidx -d /dev/loop0
       echo part1=dc7bb28d-1f79-4597-935a-fc8295704d9e
       echo part2=dcc1c297-0c91-450b-8678-256e847b47ac
       find /dev/disk
    '')
  ];

  services.getty.autologinUser = "root";

  nixos-shell.mounts.cache = "none";

  virtualisation.qemu.networkingOptions = [
    # We need to re-define our usermode network driver
    # since we are overriding the default value.
    "-net nic,netdev=user.1,model=virtio"
    # Than we can use qemu's hostfwd option to forward ports.
    "-netdev user,id=user.1,hostfwd=tcp::9273-:9273"
  ];
}
