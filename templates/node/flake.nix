{
  description = "A Plexsphere node installed over SSH with nixos-anywhere";

  inputs = {
    plexsphere-node.url = "github:plexsphere/plexsphere-node";

    # The nixpkgs revision plexsphere-node's own flake.lock pins, which is the
    # one its checks evaluate the node profile against. It is also what makes
    # system.stateVersion in node.nix name the release the node is installed
    # under, instead of whatever a second, independently locked nixpkgs input
    # happens to resolve to.
    nixpkgs.follows = "plexsphere-node/nixpkgs";

    # No disko input: plexsphere-node.nixosModules.disk imports disko's NixOS
    # module itself, at the revision plexsphere-node's flake.lock pins.
  };

  outputs = { nixpkgs, plexsphere-node, ... }:
    let
      node = system: nixpkgs.lib.nixosSystem {
        modules = [
          plexsphere-node.nixosModules.disk
          plexsphere-node.nixosModules.node
          ./node.nix

          # nixpkgs.hostPlatform rather than the system argument of
          # nixosSystem, which only sets the legacy nixpkgs.system. A plain
          # definition, so it outranks the mkDefault the generated
          # hardware-configuration.nix writes, and the attribute name below
          # alone decides which platform the node is built for.
          { nixpkgs.hostPlatform = system; }
        ]
        # Written by nixos-anywhere's --generate-hardware-config during the
        # run, so it does not exist when this flake is first evaluated, and is
        # imported from then on. It is not optional in practice. The node
        # profile names no hardware, and nixpkgs' default initrd modules cover
        # SATA, NVMe, SCSI, MMC and USB disks but no virtio device: without
        # this file, a node installed into a virtio VM does not find its root
        # disk at boot. On hardware it adds the storage controller modules and
        # the CPU microcode the defaults lack.
        ++ nixpkgs.lib.optional (builtins.pathExists ./hardware-configuration.nix)
          ./hardware-configuration.nix;
      };
    in
    {
      # One entry per architecture, so the machine's architecture is chosen on
      # the nixos-anywhere command line (--flake .#node-x86_64 or
      # --flake .#node-aarch64) and never by editing this file.
      nixosConfigurations.node-x86_64 = node "x86_64-linux";
      nixosConfigurations.node-aarch64 = node "aarch64-linux";
    };
}
