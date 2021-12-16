# NixOS based firmware image

## Design principles

 - This is based off the A/B system updates (the same we find in android[^android] 
   or ChromeOS[^chromeos]).
   The purpose of this is to reduce the probability of losing a device after an upgrade.
 - A/B (flip-flop) firmwares works by having two full system images at the same time on
   an appliance. When a firmware is running (and activated), we can safely rewrite the
   other firmware.
   Once the firmware is written, we can verify it correctly applied on the disk
   (checksum), then ask the bootloader to boot on this new firmware **on the next boot
   only**.
   Should the firmware load fail, the bootloader will then revert to the previous
   firmware.
 - By making firmwares on disk read-only, we also ensure we can not corrupt a filesystem
   (a disk block is either written or not) we only flip the bootloader configuration
   once the firmware is completely written and verified.
 - The firmware should be immutable and check for corruption. By relying on
   dm-verity[^dm-verity], we can check, on block read, that the data has not been
   tampered with.

[^android]: https://source.android.com/devices/tech/ota/ab/
[^chromeos]: https://www.chromium.org/chromium-os/chromiumos-design-docs/disk-format#TOC-Google-Chrome-OS-devices
[^dm-verity]: https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/verity.html

## Single firmware image

This is the image of a single update, to be placed in the slot A or slot B of the disk.

The firmware topology looks like:
```
   /------------\
   | partition  |
   |   table    |
   +------------+
   |   kernel   |
   |      +     |
   |  metadata  |
   +------------+
   |  readonly  |
   | filesystem |
   |   image    |
   +------------+
   | dm-verity  |
   |   merkle   |
   |    tree    |
   +------------+
   | partition  |
   |   table    |
   |  (backup)  |
   \------------/
```

readonly filesystem image includes the `/nix/store` using the `make-ext4-fs.nix` from
nixpkgs[^make-ext4-fs].
[^make-ext4-fs]: https://github.com/NixOS/nixpkgs/blob/master/nixos/lib/make-ext4-fs.nix

Once this filesystem image is built, we'll build the dm-verity merkle tree, and include
its `root-hash` in the initramfs.

The kernel and initramfs are bundled together using the systemd efi stub
(`packages/efi-kernel-make/`). This builds an efi image.
This efi image can then be signed. By checking signature on the efi image, we check:
 - the kernel
 - the initramfs bundles:
   - the root hash of the merkle tree checks:
     - the content of the merkle tree checks:
       - the content of the filesystem image includes:
         - `/nix/store` content

## Full disk image

As laid out in the design principle, this is based off A/B system updates.

So essentially this will look like:
```
   /-----------\
   | partition |
   |   table   |
   +-----------+
   |   boot    |
   |  support  |
   |   (ESP)   |
   +-----------+
   |  firmware |
   |   image   |
   |     A     |
   +-----------+
   |  firmware |
   |   image   |
   |     B     |
   +-----------+
   | accessory |
   | partition |
   |     0     |
   +-----------+
   |    ...    | 
   +-----------+
   | accessory |
   | partition |
   |     N     |
   +-----------+
   | partition |
   |   table   |
   | (backup)  |
   \-----------/
```

Boot support is expected to be a readonly fat32 partition. UEFI standard
says the efi images will be loaded from the ESP-flagged partition, formated
as fat32 filesystem.

This means, that the full picture will look like:
```
   /--------------\
   |  partition   |
   |    table     |
   +--------------+
   |    boot      |
   |   support    |
   |    (ESP)     |
   +--------------+
   |  firmware A  |
   |/------------\|
   || partition  ||
   ||   table    ||
   |+------------+|
   ||   kernel   ||
   ||      +     ||
   ||  metadata  ||
   |+------------+|
   ||  readonly  ||
   || filesystem ||
   ||   image    ||
   |+------------+|
   || dm-verity  ||
   ||   merkle   ||
   ||    tree    ||
   |+------------+|
   || partition  ||
   ||   table    ||
   ||  (backup)  ||
   |\------------/|
   |              |
   | (tail space) |
   |              |
   +--------------+
   |  firmware B  |
   |     ...      |
   +--------------+
   |     ...      |
```

Nested partition is not standard. And because the firmware brings its kernel (as
efi image) to be loaded, we need a small shim (living in the boot support
partition) to read the nested partition table, and load the kernel from
the nested partition.

This is implemented via a Rust bootloader compiled to EFI
(`packages/nestest-partition-loader`). Rust bootloader will consume UEFI
bootservices[^bootservices] to read the content of the partition table, and will
then load kernel in memory and pass that to the bootservices for the firmware to
jump on the kernel.
Should the load of the kernel fail, this returns and goes back to the systemd
bootloader (which then selects the next boot entry).

[^bootservices]: https://uefi.org/sites/default/files/resources/UEFI_Spec_2_9_2021_03_18.pdf page 143

Systemd's bootloader is the selected bootloaded, and it includes two entries for
the two firmwares. This is what is loaded by UEFI firmware (it lives in
`esp/EFI/BOOT/BOOTX64.EFI`[^bootx64]). Entries looks like:
```
title firmware A
efi /nested-partition-loader.efi
options boot-index=ed38b728-db62-4127-8962-9ef6ba2c78b0
```
(note: `ed38b728-db62-4127-8962-9ef6ba2c78b0` is the partition GUID for firmware A)

[^bootx64]: https://uefi.org/sites/default/files/resources/UEFI_Spec_2_9_2021_03_18.pdf Table 3-2 UEFI Image Types page 89

systemd bootloader supports a couple features like boot selection (default boot,
next boot) via EFI variables (readable/writable via `bootctl status`).

### Customization

UEFI provides a persistent (rom based) variable storage. It is provided to both
the kernel and boot loaders.

This can store any data, usually related to boot or boot signature, but it can be
used to store vendor data.

Although space is limited, we can use this to store any appliance customization
needed (ip configuration, appliance name, peer configuration, ...).

## Next steps

### Upgrade procedure

When applying an upgrade, the process should check the checksum of the image, write
the image to the inactive slot, checksum the image again, then write to the UEFI
variable the slot as next boot.

If the firmware fails to boot, on the next reboot, the current firmware will be
loaded as fallback.
If the firmware boots correctly it should mark itself as the new default. The other slot
can then be considered inactive.

### Live updates

Building a readonly system is nice because it makes it extremely fault resilient,
but we'll lose the ability to deploy non-disruptive updates, which is
inconvenient.

NixOS system versions are different generations stored in the `/nix/store` and are
activated on boot with `/nix/store/.../bin/activate`.

We could use one of the accessory partition to store local modifications to the `/nix/store`
because the firmware `/nix/store` and this additional content should not overlap, we
can mix them with an overlayfs[^overlayfs] mount.

[^overlayfs]: https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html

```
mkfs.ext4 /dev/vda4
mount /dev/vda4 /nix/.store-rw

# /nix/.store-ro is from the firmware image
mount -t overlay overlay -olowerdir=/nix/.store-ro,upperdir=/nix/.store-rw/content,workdir=/nix/.store-rw/work /nix/store
```

### Secureboot

Because the firmware can now be signed by just signing the EFI image (following the PE/COFF
signature format). We can enable secureboot and ensure only Awake-signed firmware
will boot on the appliance. This is required if we want to protect credential using
TPM (see next point).

### TPM

Because this firmware scheme relies on UEFI, all loaded efi images and various configuration
options will be hashed in the TPM.

The efi image we care about should be hashed in the PCR 4, but more important PCR7
should include 3 items (and only those):
 - `secureboot_enabled=true`:
```
- EventNum: 10
  PCRIndex: 7
  EventType: EV_EFI_VARIABLE_DRIVER_CONFIG
  DigestCount: 2
  Digests:
  - AlgorithmId: sha1
    Digest: "d4fdd1f14d4041494deb8fc990c45343d2277d08"
  - AlgorithmId: sha256
    Digest: "ccfc4bb32888a345bc8aeadaba552b627d99348c767681ab3141f5b01e40a40e"
  EventSize: 53
  Event:
    VariableName: 8be4df61-93ca-11d2-aa0d-00e098032b8c
    UnicodeNameLength: 10
    VariableDataLength: 1
    UnicodeName: SecureBoot
    VariableData: "01"
```
 - The secureboot keyring (the public keys allowed to sign payload): PK, KEK, db, dbx
```
- EventNum: 11
  PCRIndex: 7
  EventType: EV_EFI_VARIABLE_DRIVER_CONFIG
  DigestCount: 2
  Digests:
  - AlgorithmId: sha1
    Digest: "a27021942411bdc6ef106a5f68e4072a0119ba83"
  - AlgorithmId: sha256
    Digest: "ddd2fe434fee03440d49850277556d148b75d7cafdc4dc59e8a67cccecad1a3e"
  EventSize: 1019
  Event:
    VariableName: 8be4df61-93ca-11d2-aa0d-00e098032b8c
    UnicodeNameLength: 2
    VariableDataLength: 983
    UnicodeName: PK
    VariableData: [...]
[...]
```
 - A cap
```
- EventNum: 15
  PCRIndex: 7
  EventType: EV_SEPARATOR
  DigestCount: 2
  Digests:
  - AlgorithmId: sha1
    Digest: "9069ca78e7450a285173431b3e52c5c25299e473"
  - AlgorithmId: sha256
    Digest: "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119"
  EventSize: 4
  Event: "00000000"
```

Relying on PCR7 to lock secrets is effective (this is how microsoft locks disk
encryption key in bitlocker).

Note: the PCR7 should be extended once the secret has been recovered, to ensure a
later compromise of the system does not get access to secrets.

## Random thoughts

### Firmware encryption

If we have TPM support, we could start encrypting the firmware image and unlocking
the encryption key by making sure a trusted kernel image has been loaded.
This would ensure IP does not leak.

### Recovery image (clean image)

Instead of an A/B system, we could have an A/B/Recovery layout, with a smaller
firmware for the recovery. Recovery could be the image written by CCI. And recovery
image does not need to carry IP, and does not need to be encrypted.

### Data encryption

TPM could be used as root device for disk encryption of appliance data.
Kernel/initramfs needs to provide the disk with the encryption key on boot.

Note: it would probably require hardware-encryption capable disks (same model
but different SKU than the disks we currently use in production).

### Remote attestation

TPMs provides a way to do remote attestation of systems. This could be used to
have appliances authenticate to SSIP.

This requires two keys of the TPM, Attestation Key (AK) and Endorsement Key (EK),
those two keys need to be bound together with a rather convoluted
challenge-response mechanism.

### Remote attestation TOFU

We'd need to store all appliances endorsement keys to make sure those are the
one we shipped. This could be done either on TOFU or at CCI during staging (with
another key, only they have access to).

### Multiple signatures with build reproducibility

If we get the firmware fully build-reproducible, we can ship firmware with two
signatures provided by two independent build chains. This should offer some
resistance to supply chain tempering and would benefit auditability of our
firmware images.

This multi signature check can be implemented in the rust shim.
