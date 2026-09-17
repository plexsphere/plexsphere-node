{ lib, pkgs, modulesPath, ... }:

let
  imageName = "plexsphere-node-image-${pkgs.stdenv.hostPlatform.system}";
in
{
  # virtio_blk, virtio_pci, virtio_scsi and virtio_net in the initrd.
  # nixpkgs' default initrd modules carry no virtio driver, so without these
  # the image does not find its root disk on any virtio hypervisor, which
  # every OpenStack cloud and every local QEMU is.
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  # The image is one disk for every instance booted from it, so it carries no
  # identity. An empty networking.hostName leaves the name to cloud-init,
  # which sets it from the datasource at first boot, and
  # plexsphere.node.sshAuthorizedKeys keeps its empty default, which the node
  # module accepts because cloud-init is enabled below and writes root's keys.
  plexsphere.node.hostName = "";

  # disko requires a device, and the image builder never uses this one: the
  # system it installs is extended with every disk and
  # boot.loader.grub.devices forced to /dev/vda (disko lib/make-disk-image.nix
  # and prepareDiskoConfig in lib/tests.nix). The placeholder therefore only
  # exists in the evaluated configuration, where a name that resolves nowhere
  # cannot be mistaken for a real disk.
  plexsphere.disk.device = "/dev/disk/by-id/REPLACE-ME-substituted-by-the-image-builder";

  # x86 OpenStack instances boot with SeaBIOS unless the image is registered
  # with hw_firmware_type=uefi, so the x86_64 image boots from both. aarch64
  # has UEFI only and stays on systemd-boot.
  plexsphere.disk.biosBoot = pkgs.stdenv.hostPlatform.isx86_64;

  # Both loaders install to the removable EFI path; a cloud instance has no
  # NVRAM entry to write and may not persist one.
  boot.loader.efi.canTouchEfiVariables = false;

  # 4G holds the 1M BIOS boot partition, the 1G ESP and about 3G of root for
  # the node closure. The builder names its output after imageName.
  disko.devices.disk.main.imageName = imageName;
  disko.devices.disk.main.imageSize = "4G";

  # The default is "${networking.hostName}-disko-images", which with the
  # empty host name above yields a derivation name beginning with "-".
  disko.imageBuilder.name = imageName;

  # The builder writes the raw disk it booted; a compressed qcow2 is what
  # Glance and QEMU take directly. The raw file is removed so the output
  # holds one image.
  disko.imageBuilder.imageFormat = "raw";
  disko.imageBuilder.extraPostVM = ''
    ${pkgs.qemu-utils}/bin/qemu-img convert -f raw -O qcow2 -c \
      "$out/${imageName}.raw" \
      "$out/${imageName}.qcow2"
    rm "$out/${imageName}.raw"
  '';

  # The builder VM runs nixos-install over the whole node closure, and
  # disko's default of 1024 MiB is the value its documentation tells users
  # to raise first.
  disko.memSize = 2048;

  # Grow the root partition and its ext4 to the volume the instance gets.
  # growPartition runs growpart before systemd-growfs-root.service, and
  # autoResize adds x-systemd.growfs to the mount. This lives on the NixOS
  # side rather than in cloud-init's growpart module, so the root grows even
  # when no datasource is found.
  boot.growPartition = true;
  fileSystems."/".autoResize = true;

  # The serial console is what `openstack console log show` and QEMU's
  # -serial read, and systemd's getty generator spawns a login on it, which
  # keeps a console credential from plexsphere.node.hashedPasswordFile
  # reachable. tty1 keeps the graphical console.
  boot.kernelParams = [
    "console=tty1"
    "console=${if pkgs.stdenv.hostPlatform.isx86_64 then "ttyS0" else "ttyAMA0"},115200n8"
  ];

  # cloud-init renders the datasource's network configuration (OpenStack's
  # network_data.json, a NoCloud network-config) as networkd units, and
  # useNetworkd makes networkd the only backend, so dhcpcd does not compete
  # with it. The node module's useDHCP default becomes networkd's
  # 99-ethernet-default-dhcp.network, which cloud-init's 10-cloud-init-*
  # files outrank by name: static addresses from a datasource win, and a
  # datasource that hands out none falls back to DHCP.
  services.cloud-init.enable = true;
  services.cloud-init.network.enable = true;
  networking.useNetworkd = true;

  # cloud-init.service writes the host name, root's keys and the user-data's
  # write_files, and cloud-final.service runs its runcmd. k3s and plexd
  # otherwise start at network-online.target, the same point cloud-init
  # starts at, so k3s could register its Node object under the host name
  # from before cloud-init and plexd could start before
  # /etc/plexd/bootstrap-token exists. Ordering only, never wants or
  # requires: when no datasource is found, cloud-init.service fails,
  # cloud-final.service never starts, and k3s and plexd still have to come up.
  systemd.services.k3s.after = [ "cloud-final.service" ];
  systemd.services.plexd.after = [ "cloud-final.service" ];
}
