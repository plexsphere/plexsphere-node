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

    # plexd refuses to start on a malformed tunnel.session_signing_public_key,
    # even with tunneling disabled, and restarts on that error forever, which
    # drops the node off the mesh. The type holds the value to the one shape
    # plexd accepts, 32 bytes as standard base64, so a mistyped key fails
    # evaluation instead. It is stricter than plexd in two places: plexd
    # trims whitespace and reads "" as unset, where null is the way to leave
    # the key unset here and a key read from a file goes through lib.trim.
    sessionSigningPublicKey = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9+/]{43}=");
      default = null;
      example = "4U1YI+YiHKMzeEXxk10y3mdBhsYxwmSrV9n3RSlmTRg=";
      description = ''
        The Domain's session-signing public key, as 44 characters of standard
        base64, rendered to tunnel.session_signing_public_key. When set, plexd's
        session helper trusts only this key. When null, the helper copies
        signing_public_key from identity.json to /etc/plexd/session-signing-key
        on its first run and trusts that file afterwards; setting the key at
        provisioning closes that trust-on-first-use window. The helper does not
        follow a signing-key rotation: after one, set the Domain's new key here.
        It is a public key, so the world-readable Nix store holds nothing secret.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Preset via mkDefault so any host-level api.base_url still wins.
      services.plexd.settings.api.base_url = lib.mkDefault "https://api.plexsphere.com";
    }

    # Around the whole definition rather than the leaf: pushed down to the
    # value, the condition would still leave an empty tunnel block in the
    # rendered file of every node that sets no key.
    (lib.mkIf (cfg.sessionSigningPublicKey != null) {
      services.plexd.settings.tunnel.session_signing_public_key = cfg.sessionSigningPublicKey;
    })

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
      # network. Within the mesh it is wide open. A tcp session's forward is
      # unauthenticated (the first peer to connect takes the session), an ssh
      # session's listener takes the session token as its password, and
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
        # plexd hands every ssh session's shell to the helper behind this
        # socket and falls back to a child inside its own sandbox when the
        # socket is missing, where the shell cannot switch users.
        after = [ "network-online.target" "plexd-session-helper.socket" ];
        wants = [ "network-online.target" "plexd-session-helper.socket" ];
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

      # plexd v0.8.0 serves mediated ssh sessions but starts no shell itself:
      # the sandbox above bounds it to CAP_NET_ADMIN and CAP_NET_RAW and hides
      # /home, so a process it forks cannot become the login user. It sends
      # each launch to this socket instead, where systemd starts one root
      # helper per connection. Both units mirror plexd's own
      # deploy/systemd/plexd-session-helper.socket and
      # plexd-session-helper@.service. The socket stays reachable from the
      # sandbox: /run/plexd-session-helper.sock is under no InaccessiblePaths
      # entry, and AF_UNIX is allowed. No Also= line: NixOS enables units
      # through wantedBy, and plexd's Wants= pulls the socket in as well.
      systemd.sockets.plexd-session-helper = {
        description = "plexd session helper socket";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "/run/plexd-session-helper.sock" ];
        socketConfig = {
          SocketMode = "0600";
          SocketUser = "root";
          SocketGroup = "root";
          Accept = true;
          MaxConnections = 512;
          TriggerLimitIntervalSec = 0;
        };
      };

      # No sandbox, deliberately: the helper exists to run as unconfined
      # root, so it can switch to the login user and reach its home. Its
      # guard is the token check. It verifies every session token again,
      # against tunnel.session_signing_public_key or the key it pinned at
      # /etc/plexd/session-signing-key, and plexd cannot write /etc to
      # replace either. --config also decides where that pin lives: beside
      # the config file.
      #
      # Each instance holds one accepted connection, which a restarted
      # instance cannot get back, so restarting one on nixos-rebuild switch
      # would only kill the running shell. The next connection starts an
      # instance of the new unit anyway.
      systemd.services."plexd-session-helper@" = {
        description = "plexd session helper (one mediated ssh process)";
        restartIfChanged = false;
        unitConfig.CollectMode = "inactive-or-failed";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.package}/bin/plexd session-helper --config /etc/plexd/config.yaml";
          StandardInput = "null";
          StandardOutput = "journal";
          StandardError = "journal";
          KillMode = "control-group";
        };
      };
    })
  ];
}
