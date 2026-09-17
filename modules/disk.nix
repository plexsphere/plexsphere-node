{ config, lib, pkgs, ... }:

let
  cfg = config.plexsphere.disk;
in
{
  options.plexsphere.disk = {
    device = lib.mkOption {
      type = lib.types.str;
      example = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1234567890";
      description = ''
        Disk the disko layout is applied to. Applying the layout rewrites the
        partition table and destroys all data on this device, so there is
        deliberately no default — name it per host, preferably as a stable
        /dev/disk/by-id or /dev/disk/by-path identifier. Kernel names such as
        /dev/sda are assigned in probe order and can resolve to a different
        physical disk between boots.
      '';
    };

    biosBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Boot with GRUB in hybrid mode, from legacy BIOS firmware and from UEFI,
        instead of with systemd-boot from UEFI only. Adds a 1M BIOS boot
        partition (GPT type EF02) in front of the ESP, installs GRUB's i386-pc
        image into it and its EFI image at the removable path
        EFI/BOOT/BOOTX64.EFI. x86_64 only: there is no BIOS on aarch64, and the
        aarch64 GRUB package carries no i386-pc target. The machine image sets
        this; the live USB installer and the SSH takeover stay on systemd-boot.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.biosBoot -> pkgs.stdenv.hostPlatform.isx86_64;
        message = "plexsphere.disk.biosBoot needs an x86_64 node: there is no BIOS on aarch64, and the aarch64 GRUB package has no i386-pc target for the BIOS boot partition";
      }
    ];

    disko.devices.disk.main = {
      device = cfg.device;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            type = "EF00";
            # A kernel plus an initrd with firmware is well over 100M per
            # generation, and systemd-boot keeps every generation it is given.
            # 1G alongside the configurationLimit below leaves headroom.
            size = "1G";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              # vfat carries no permission bits: without a umask the kernel
              # exposes the kernel, initrd and loader entries as 0755.
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        }
        # Where GRUB's i386-pc core image lives, since a GPT disk has no gap
        # behind the MBR for it. disko creates an EF02 partition first and
        # adds the disk to boot.loader.grub.devices by itself
        # (lib/types/gpt.nix), so this module must not set that option too:
        # a second definition would make install-grub.pl run grub-install
        # twice on the same device.
        // lib.optionalAttrs cfg.biosBoot {
          boot = {
            type = "EF02";
            size = "1M";
          };
        };
      };
    };

    # The boot loader lives here, not in the node module, so existing
    # machines keep theirs when importing only the node profile.
    # systemd-boot from UEFI on both architectures by default; GRUB in hybrid
    # mode with biosBoot, on x86_64 only.
    boot.loader.systemd-boot.enable = lib.mkDefault (!cfg.biosBoot);
    # nixpkgs' GRUB module asserts efiInstallAsRemovable ->
    # !canTouchEfiVariables: the removable path is what UEFI firmware falls
    # back to when no boot entry exists, so there is no entry to write.
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault (!cfg.biosBoot);

    # Unbounded is the NixOS default: every kernel-changing generation copies
    # another kernel and initrd into the ESP until nixos-rebuild switch fails
    # in the bootloader install step, after the system profile has already
    # advanced. A node that cannot update is a node that cannot be fixed.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 5;

    # efiInstallAsRemovable puts BOOTX64.EFI at EFI/BOOT, the path UEFI
    # firmware boots when NVRAM holds no entry, which is the state of every
    # fresh cloud instance. The configurationLimit covers the same ESP
    # exhaustion as the systemd-boot one above.
    boot.loader.grub = lib.mkIf cfg.biosBoot {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      configurationLimit = lib.mkDefault 5;
    };
  };
}
