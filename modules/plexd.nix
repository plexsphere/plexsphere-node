{ config, lib, pkgs, ... }:

let
  cfg = config.services.plexd;
  yamlFormat = pkgs.formats.yaml { };
  configFile = yamlFormat.generate "plexd-config.yaml" cfg.settings;
in
{
  options.services.plexd = {
    enable = lib.mkEnableOption "plexd node agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/plexd.nix { };
      defaultText = lib.literalMD "the pinned plexd release binary from this flake (`packages/plexd.nix`)";
      description = "The plexd package to run.";
    };

    settings = lib.mkOption {
      type = yamlFormat.type;
      default = { };
      description = ''
        Freeform (RFC 42) plexd settings rendered to /etc/plexd/config.yaml.

        The rendered file is generated into the world-readable Nix store, so
        it must not carry credentials. Deliver the registration token out of
        band instead: /etc/plexd/bootstrap-token, or PLEXD_BOOTSTRAP_TOKEN via
        /etc/plexd/environment.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Preset via mkDefault so any host-level api.base_url still wins.
      services.plexd.settings.api.base_url = lib.mkDefault "https://api.plexsphere.com";
    }

    (lib.mkIf cfg.enable {
      environment.etc."plexd/config.yaml" = {
        source = configFile;
        # A mode makes NixOS copy the file into /etc instead of symlinking the
        # store path there. It keeps /etc tidy next to the 0600 token file —
        # it is not a confidentiality control: the same bytes stay readable by
        # everyone at the store path this is copied from, which is why the
        # settings option carries no credentials.
        mode = "0600";
        user = "root";
        group = "root";
      };

      # Peers hand shake into plexd's WireGuard port, so a host firewall in
      # front of it drops inbound mesh traffic. Unlike Flannel's VXLAN this is
      # authenticated and silent to unauthenticated probes, so it is safe to
      # expose. Read from settings so a changed listen_port stays in step;
      # plexd's bridge features (relay, user access, site-to-site) are off by
      # default and need their own ports opened when enabled.
      networking.firewall.allowedUDPPorts = [
        (cfg.settings.wireguard.listen_port or 51820)
      ];

      # Remote sessions from the control plane arrive over the mesh: plexd
      # binds each session's listener to the node's mesh IP on a port the
      # kernel picks, so the whole of the kernel's default ephemeral range
      # (net.ipv4.ip_local_port_range, 32768-60999) has to be open. Only on
      # the WireGuard interface, which follows interface_name: plexd's own
      # nftables chain hooks forward and never filters traffic addressed to
      # the host, so this rule is what keeps the range off every other
      # network. Within the mesh it is wide open. The session forward is
      # unauthenticated (the first peer to connect takes the session), and
      # any other socket bound to an ephemeral port on the mesh IP or the
      # wildcard address answers every peer too. Not tied to tunnel.enabled:
      # plexd forces that back on unless max_sessions is also set, so a
      # condition here would disagree with the binary.
      networking.firewall.interfaces.${cfg.settings.wireguard.interface_name or "plexd0"}.allowedTCPPortRanges = [
        { from = 32768; to = 60999; }
      ];

      # The same directory holds the out-of-band bootstrap token and
      # environment file; NixOS would otherwise create it world-readable.
      systemd.tmpfiles.settings."10-plexd"."/etc/plexd".d = {
        user = "root";
        group = "root";
        mode = "0750";
      };

      systemd.services.plexd = {
        description = "plexd node agent";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # No start rate limit, unlike upstream's StartLimitBurst=5: plexd is
        # the node's only link to the control plane, so parking the unit in
        # "failed" after a burst of quick exits would drop the node off the
        # mesh with nothing left to recover it.
        startLimitIntervalSec = 0;
        # /etc/plexd/config.yaml lives outside the unit, so restart on change.
        restartTriggers = [ configFile ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.package}/bin/plexd up --config /etc/plexd/config.yaml";
          Restart = "always";
          RestartSec = "5s";
          LimitNOFILE = 65536;
          EnvironmentFile = "-/etc/plexd/environment";
          # plexd drives nftables and reads the root-only bootstrap token, so
          # it runs as root; the sandbox below is what bounds a compromise of
          # this network-facing parser away from the k3s CA and join token.
          AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_RAW";
          CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_RAW";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          # ProtectSystem only makes the hierarchy read-only, and a UID-0
          # process matches the owner class on k3s' 0600/0700 files, so
          # dropping DAC_OVERRIDE does not stop a read either. Masking the
          # paths is what actually keeps the cluster CA private key, the join
          # token, the Secret encryption key and the admin kubeconfig out of
          # reach of this parser.
          #
          # The read-only remount does not cover sockets: the kernel rejects
          # writes to a read-only mount for regular files, directories and
          # symlinks only, so connect() still succeeds — and AF_UNIX is in the
          # allow-list below. As UID 0 this unit would otherwise reach
          # systemd's private socket, where StartTransientUnit spawns a fresh
          # root unit carrying none of these directives, or containerd's,
          # where a container with / bind-mounted reads the masked paths
          # straight off the host. Mask those sockets too.
          InaccessiblePaths = [
            "-/var/lib/rancher"
            "-/etc/rancher"
            "-/var/lib/kubelet"
            "-/run/systemd/private"
            "-/run/k3s"
            "-/run/containerd"
            "-/run/dbus"
          ];
          ProtectProc = "invisible";
          PrivateDevices = true;
          ProtectClock = true;
          ProtectKernelLogs = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectKernelModules = true;
          RestrictNamespaces = true;
          RestrictSUIDSGID = true;
          # AF_NETLINK is how plexd talks to nftables.
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
          LockPersonality = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@obsolete" ];
          # Create the runtime/state dirs instead of upstream's
          # ReadWritePaths=/var/lib/plexd /var/run/plexd.
          StateDirectory = "plexd";
          RuntimeDirectory = "plexd";
        };
      };
    })
  ];
}
