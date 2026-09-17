{ ... }:

{
  # k3s derives the Kubernetes node name from this, so it must be unique across
  # the cluster and match ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$.
  plexsphere.node.hostName = "plex-node-01";

  # At least one root SSH key in ssh-keygen form; password authentication is
  # off, so evaluation fails on an empty list or a malformed key.
  plexsphere.node.sshAuthorizedKeys = [
    # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... you@laptop"
  ];

  # The disk this install wipes, as a /dev/disk/by-id alias read off the
  # target machine: kernel names such as /dev/sda can name a different disk
  # on the next boot.
  plexsphere.disk.device = "/dev/disk/by-id/REPLACE-ME";

  # A console-only root password, read from a mkpasswd hash that nixos-anywhere
  # --extra-files delivers to this path; set both or neither.
  # plexsphere.node.hashedPasswordFile = "/etc/plexsphere/root-password-hash";

  # The control plane plexd registers with, when it is not
  # https://api.plexsphere.com.
  # services.plexd.settings.api.base_url = "https://cp.example.test";

  # The nixpkgs release this node is installed under; leave it unchanged
  # after the install.
  system.stateVersion = "26.05";
}
