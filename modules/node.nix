{ config, lib, ... }:

let
  cfg = config.plexsphere.node;

  # sshd rewrites authorized_keys and skips every line it cannot parse, so a
  # truncated or half-substituted key passes a non-emptiness check and still
  # leaves the node unreachable. Match the wire format instead: key type,
  # base64 blob, optional comment. Option prefixes (restrict, command=, ...)
  # are deliberately not accepted — set those through
  # users.users.root.openssh.authorizedKeys.keys directly.
  #
  # sshd reads the key type from inside the blob, not from the label in front
  # of it, so both halves have to be pinned. Each pattern below starts with
  # the base64 encoding of the type string its blob must carry — that is what
  # ties blob to label — and then fixes the blob length. A bare
  # "[A-Za-z0-9+/]{32,}" floor did neither: 46 of an ed25519 key's 68
  # characters satisfied it, which is exactly what a truncated paste looks
  # like. ed25519 and the three ECDSA curves have one blob length each, so
  # those are exact; RSA and the FIDO types vary with key size and application
  # string, so they only get a floor — for RSA that of a 2048-bit blob, which
  # also rejects the weaker sizes ssh-keygen still accepts.
  keyPatterns = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]{48}"
    "ssh-rsa AAAAB3NzaC1yc2EA[A-Za-z0-9+/]{356,}={0,2}"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAy[A-Za-z0-9+/]{95}="
    "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAz[A-Za-z0-9+/]{138}=="
    "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1[A-Za-z0-9+/]{186}=="
    "sk-ssh-ed25519@openssh\\.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t[A-Za-z0-9+/]{59,}={0,2}"
    "sk-ecdsa-sha2-nistp256@openssh\\.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5j[A-Za-z0-9+/]{122,}={0,2}"
  ];

  isPublicKey = key:
    lib.any (pattern: builtins.match "${pattern}( .*)?" key != null) keyPatterns;
in
{
  imports = [ ./plexd.nix ];

  options.plexsphere.node = {
    hostName = lib.mkOption {
      type = lib.types.str;
      example = "plex-node-01";
      description = ''
        Network host name of the Plexsphere node. k3s derives the Kubernetes
        node name from it, so it must be unique across the cluster; there is
        deliberately no default.
      '';
    };

    sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys authorized for root login on the node, each in the
        `<type> <base64> [comment]` form `ssh-keygen` emits.

        Must be non-empty and syntactically valid: password authentication is
        disabled, and sshd silently skips a malformed line, so either mistake
        leaves the node unreachable after rebuild.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.sshAuthorizedKeys != [ ] && lib.all isPublicKey cfg.sshAuthorizedKeys;
        message = "plexsphere.node.sshAuthorizedKeys must hold at least one syntactically valid OpenSSH public key ('<type> <base64> [comment]'). Password authentication is disabled on Plexsphere nodes and sshd skips a malformed key without failing, so an empty or mistyped list leaves the node unreachable after rebuild.";
      }
    ];

    networking.hostName = cfg.hostName;

    users.users.root.openssh.authorizedKeys.keys = cfg.sshAuthorizedKeys;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    services.k3s.enable = lib.mkDefault true;
    services.k3s.role = lib.mkDefault "server";

    # Encrypts Secret values at rest in the datastore. k3s keeps the AES key
    # in server/cred/encryption-config.json under the same unencrypted root
    # filesystem, so this does not defend against offline access to the disk;
    # it bounds a leak of the datastore alone, such as a copied database file
    # or a backup that excludes the credential directory. Enabling it on an
    # already-running server encrypts newly written Secrets only — see the
    # README for the re-encryption step. Server-only flag.
    services.k3s.extraFlags =
      lib.mkIf (config.services.k3s.role == "server") [ "--secrets-encryption" ];

    services.plexd.enable = lib.mkDefault true;

    # plexd's nftables table hooks forward, not input: it enforces mesh peer
    # policy on packets routed between peers and never filters traffic
    # addressed to this host. It is therefore not a host packet filter and
    # does not compete with one, so the NixOS firewall stays enabled (its
    # default) and keeps k3s (6443, 10250, 8472/udp) off attached networks.
    #
    # Pod traffic to the apiserver and the kubelet arrives on the input hook
    # over the CNI devices, so those two ports are opened on those two devices
    # rather than on every attached network. The devices are deliberately not
    # marked trusted: trustedInterfaces accepts every port, which would hand
    # sshd and anything else bound to 0.0.0.0 to every pod on the node — and
    # to anything that can reach Flannel's unauthenticated VXLAN port, since a
    # frame whose inner destination is the node's own address is decapsulated
    # and delivered on flannel.1.
    networking.firewall.interfaces = {
      cni0.allowedTCPPorts = [ 6443 10250 ];
      "flannel.1".allowedTCPPorts = [ 6443 10250 ];
    };

    networking.useDHCP = lib.mkDefault true;

    time.timeZone = lib.mkDefault "UTC";
  };
}
