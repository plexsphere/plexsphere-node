{ config, lib, ... }:

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
  };

  config = {
    disko.devices.disk.main = {
      device = config.plexsphere.disk.device;
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
        };
      };
    };

    # The boot loader lives here, not in the node module, so existing
    # machines keep theirs when importing only the node profile. UEFI
    # only, both architectures.
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

    # Unbounded is the NixOS default: every kernel-changing generation copies
    # another kernel and initrd into the ESP until nixos-rebuild switch fails
    # in the bootloader install step, after the system profile has already
    # advanced. A node that cannot update is a node that cannot be fixed.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 5;
  };
}
