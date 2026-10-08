{
  description = "Shared base configuration for Plexsphere nodes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko }:
    let
      lib = nixpkgs.lib;

      # plexsphere.node asserts that every entry is a syntactically valid key
      # — sshd skips malformed lines silently, so a deliberately broken
      # placeholder would reproduce the lockout the assertion exists to catch.
      # A real key it has to be, and it must stay out of every deployable
      # output: this flake exposes the example hosts as a check that evaluates
      # them, not as nixosConfigurations, so nothing here installs this key on
      # a machine. It is a throwaway generated for this repository and still
      # has to be replaced.
      placeholderKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPXc2jaNRNicoagGmYKp3Qxjo/+7Kgr0M+N8gTeqpli placeholder@example.invalid";

      # plexsphere-ca-trust and the cacert build behind
      # plexsphere.node.extraCACertificates parse every certificate they are
      # given, so the checks need a real one. A self-signed throwaway CA
      # generated once for this repository with
      #   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      #     -keyout /dev/null -days 36500 -subj '/CN=plexsphere-node check CA'
      # Its key was never written anywhere, so nothing can be signed with it,
      # and like placeholderKey it stays out of every deployable output.
      placeholderCA = ''
        -----BEGIN CERTIFICATE-----
        MIIBnTCCAUOgAwIBAgIUDQU+c26sCqV3ozPQV/MgaXseM3gwCgYIKoZIzj0EAwIw
        IzEhMB8GA1UEAwwYcGxleHNwaGVyZS1ub2RlIGNoZWNrIENBMCAXDTI2MTAwODE3
        NTIwOVoYDzIxMjYwOTE0MTc1MjA5WjAjMSEwHwYDVQQDDBhwbGV4c3BoZXJlLW5v
        ZGUgY2hlY2sgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT4aLPDvGbjAqqv
        fWgEkpALzva+I0trCDSo793r7npKxp9g/cEOoUg22wgz9zHS8thGnM+e2ZsO1dVt
        x6Y73Vajo1MwUTAdBgNVHQ4EFgQU7jhxeH4MARyrUPBZKtn+kQqFLYMwHwYDVR0j
        BBgwFoAU7jhxeH4MARyrUPBZKtn+kQqFLYMwDwYDVR0TAQH/BAUwAwEB/zAKBggq
        hkjOPQQDAgNIADBFAiEAz3HiK4FSkjHEoNlLTDtfPz5s+gcMVCirrEDwX8Wc+oAC
        ICJu1hymFYvpNwUsJTb0OmkTFgvGUlEQBQg5TE6f4Q1L
        -----END CERTIFICATE-----
      '';

      # The entry the live installer writes: it takes openssl's PEM through a
      # command substitution, which drops the final newline a file ends in.
      installerCA = lib.removeSuffix "\n" placeholderCA;

      # The markers of a private key around a body that is none, so no key
      # is committed: what the checks need is the BEGIN line a key brings.
      fakeKey = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n";

      exampleModule = {
        system.stateVersion = "26.05";

        plexsphere.node.hostName = "plexsphere-example";

        plexsphere.node.sshAuthorizedKeys = [ placeholderKey ];

        # Placeholder, not a real disk: applying the layout destroys the named
        # device, so an example must not resolve to one.
        plexsphere.disk.device = "/dev/disk/by-id/REPLACE-ME-example-disk";
      };

      exampleHost = system: lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.disk self.nixosModules.node exampleModule ];
      };

      # The operator's host flake from templates/node, evaluated with this
      # checkout standing in for its github:plexsphere/plexsphere-node input.
      # Importing the template's own flake.nix instead of restating what it
      # composes is what lets a check here catch a module change that breaks
      # the file an operator instantiates, and substituting self for the input
      # keeps that check offline and pointed at the modules under review
      # rather than at whatever the default branch holds.
      takeoverHost = system: modules:
        ((import ./templates/node/flake.nix).outputs {
          inherit nixpkgs;
          plexsphere-node = self;
        }).nixosConfigurations."node-${lib.removeSuffix "-linux" system}".extendModules {
          inherit modules;
        };

      # What the live installer installs. Identity is deliberately absent:
      # plexsphere.node.hostName has no default, so a target throws until the
      # installer injects the identity it collected on the console, and
      # plexsphere.node.sshAuthorizedKeys keeps its empty default, so no key
      # from this repository can reach an installed node.
      #
      # The disk device is the one exception, and it needs both halves of what
      # mkDefault gives: disko-install reads
      # originalSystem.config.disko.devices.disk (install-cli.nix:32) before it
      # applies the --system-config module, so the option has to resolve to
      # something — while the installer's own definition, plain at priority
      # 100, still has to win, because --system-config takes a module parsed
      # from JSON and JSON cannot express mkForce.
      installTarget = system: lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.disk
          self.nixosModules.node
          {
            system.stateVersion = "26.05";

            plexsphere.disk.device =
              lib.mkDefault "/dev/disk/by-id/REPLACE-ME-supplied-by-the-installer";
          }
        ];
      };

      # The flake disko-install is actually handed, because this one exports
      # no nixosConfigurations for it to resolve. Built per system rather than
      # once: the derivation carries its own system and has to be realisable
      # in the closure of the ISO that ships it, even though the text it
      # writes is identical for both.
      installTargetFlakeFor = system:
        nixpkgs.legacyPackages.${system}.callPackage ./packages/install-target-flake.nix {
          flakeSource = self;
        };

      # One helper for both the package output and the ISO that will ship the
      # script, so the derivation an operator runs is the one writeShellApplication
      # put through shellcheck at build time.
      plexsphereInstallFor = system:
        nixpkgs.legacyPackages.${system}.callPackage ./packages/plexsphere-install.nix {
          diskoInstall = disko.packages.${system}.disko-install;
          targetFlake = installTargetFlakeFor system;
          targetAttr = system;
        };

      # The live medium. Local and unexported on purpose: a nixosModules entry
      # would offer modules/installer.nix as something an operator could import
      # into a host configuration — where it would turn that host into an
      # installation CD. The ISO packages are the whole interface.
      #
      # The script is the derivation built right above rather than one the
      # medium constructs of its own: plexsphere-install is parameterised at
      # build time with the flake reference and the target attribute it
      # installs, and a second derivation here would be one no check covers.
      installerSystem = system: lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/installer.nix
          { environment.systemPackages = [ (plexsphereInstallFor system) ]; }
        ];
      };

      # Evaluated once per system and shared by the package and the checks.
      installerSystems = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] installerSystem;

      # The machine image: the node of nixosModules.disk and nixosModules.node,
      # with cloud-init supplying the identity at first boot. Local and
      # unexported for the reason the medium above is: modules/image.nix as
      # a nixosModules entry would turn the host importing it into an image
      # that hands its host name and root keys to whatever datasource it
      # finds. nixosModules.disk imports disko's NixOS module, which is what
      # provides system.build.diskoImages.
      imageSystem = system: lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.disk
          self.nixosModules.node
          ./modules/image.nix
          { system.stateVersion = "26.05"; }
        ];
      };

      # Evaluated once per system and shared by the package and the checks.
      imageSystems = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] imageSystem;

      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      # The checks below force single options instead of instantiating a
      # system closure, so each one stays cheap. hostName and sshKey are the
      # two values every node must supply; a check pinning one leaves it out.
      hostName = { plexsphere.node.hostName = "check-node"; };
      sshKey = { plexsphere.node.sshAuthorizedKeys = [ placeholderKey ]; };

      evalNode = modules: lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ self.nixosModules.node { system.stateVersion = "26.05"; } ] ++ modules;
      };

      defaultNode = evalNode [ hostName sshKey ];

      assertionFired = host: fragment:
        lib.any (a: !a.assertion && lib.hasInfix fragment a.message) host.config.assertions;

      evalThrows = value: !(builtins.tryEval (builtins.seq value true)).success;

      passIf = name: condition: message:
        if condition then pkgs.runCommand name { } "touch $out" else throw "${name}: ${message}";
    in
    {
      nixosModules.node = ./modules/node.nix;

      nixosModules.disk = {
        imports = [ disko.nixosModules.disko ./modules/disk.nix ];
      };

      packages = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
        plexd = nixpkgs.legacyPackages.${system}.callPackage ./packages/plexd.nix { };

        plexsphere-install = plexsphereInstallFor system;

        installer-iso = installerSystems.${system}.config.system.build.isoImage;

        image = imageSystems.${system}.config.system.build.diskoImages;
      });

      # Not the lib bound above — this is the flake output named lib, and the
      # name is doing work rather than describing anything: nix knows it and
      # deliberately does not check it, so the targets below stay unforced.
      # Under nixosConfigurations they would be forced, which no identity-free
      # target survives, and they would sit in a `nixos-rebuild switch --flake
      # .#…` attribute path (see example-hosts-evaluate). disko-install reaches
      # them by name through a flake generated at ISO build time, so the
      # attribute names below — the systems — are what the installer asks for.
      lib.installTargets = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] installTarget;

      # The SSH takeover path. nixos-anywhere installs a nixosConfigurations
      # entry, which this flake deliberately exports none of (see
      # example-hosts-evaluate), and an entry that could install anything
      # would carry a host name, root keys and a disk that belong to one
      # machine rather than to this repository. So the entry lives in a flake
      # the operator owns, and this template is where it comes from:
      # nix flake init -t github:plexsphere/plexsphere-node#node. welcomeText
      # is printed right after the files are written, which is when the
      # operator has to learn that node.nix is theirs to fill in.
      templates.node = {
        path = ./templates/node;
        description = "A Plexsphere node installed over SSH with nixos-anywhere";
        welcomeText = ''
          Edit node.nix: the host name, at least one root SSH key, and the disk to install onto.
          Then run nixos-anywhere against the machine as described in
          https://github.com/plexsphere/plexsphere-node#take-over-a-machine-over-ssh
        '';
      };

      checks.x86_64-linux = {
        # Both example hosts set a key, so without this check only the passing
        # branch of the assertion would ever be evaluated.
        keyless-node-rejected = passIf "keyless-node-rejected"
          (assertionFired (evalNode [ hostName ]) "sshAuthorizedKeys"
            && !(assertionFired defaultNode "sshAuthorizedKeys"))
          "a node without plexsphere.node.sshAuthorizedKeys must fail the assertion";

        # A non-emptiness check passes on a truncated or half-substituted key,
        # but sshd skips the line and the node loses its only login method.
        malformed-key-rejected = passIf "malformed-key-rejected"
          (lib.all
            (key: assertionFired
              (evalNode [ hostName { plexsphere.node.sshAuthorizedKeys = [ key ]; } ])
              "sshAuthorizedKeys")
            [
              # Half-substituted: the character set gives this one away.
              "ssh-ed25519 AAAA-REPLACE-ME me@example.invalid"
              # Truncated paste — 38 of an ed25519 key's 68 characters. Every
              # character is legal base64 and only the length is wrong, so no
              # character-set check can see it.
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPXc2jaNRNico ops@laptop"
              # Label disagreeing with the type encoded in the blob. sshd
              # reads the blob, so it is the blob that decides.
              ("ssh-rsa " + lib.removePrefix "ssh-ed25519 " placeholderKey)
            ])
          "a syntactically invalid plexsphere.node.sshAuthorizedKeys entry must fail the assertion";

        # The machine image carries no key and leaves root's keys to
        # cloud-init, so the emptiness half of the assertion gives way to
        # services.cloud-init.enable. The validity half must not give way
        # with it: sshd skips a malformed line whether or not cloud-init adds
        # more, and keyless-node-rejected keeps covering a node that has
        # neither.
        keyless-node-allowed-with-cloud-init = passIf "keyless-node-allowed-with-cloud-init"
          (!(assertionFired
            (evalNode [ hostName { services.cloud-init.enable = true; } ])
            "sshAuthorizedKeys")
            && assertionFired
              (evalNode [
                hostName
                {
                  services.cloud-init.enable = true;
                  plexsphere.node.sshAuthorizedKeys = [ "ssh-ed25519 AAAA-REPLACE-ME me@example.invalid" ];
                }
              ])
              "sshAuthorizedKeys")
          "with services.cloud-init.enable an empty plexsphere.node.sshAuthorizedKeys must pass the assertion and a malformed entry must still fail it";

        # The shapes above are what a paste gets wrong. These four are what
        # ssh-keygen -l accepts and this option does not, which makes them the
        # rule the installer has to restate: it fingerprints fetched keys with
        # ssh-keygen and would otherwise print every one of them as
        # authorized, take the operator's confirmation, and fail this
        # assertion once disko-install builds the closure — with every answer
        # already given. The installer deals with them at the prompt instead
        # (packages/plexsphere-install.nix): it rejects the first two outright
        # and normalizes the last two, which are whitespace and not identity.
        # Relaxing a rule here has to change that script too.
        installer-key-rules-match-the-module =
          let
            # https://github.com/<user>.keys emits keys with no comment, which
            # is what puts the carriage return of a CRLF file directly behind
            # the blob — where the optional comment group, which starts with a
            # literal space, cannot absorb it.
            commentless =
              lib.concatStringsSep " " (lib.take 2 (lib.splitString " " placeholderKey));
          in
          passIf "installer-key-rules-match-the-module"
            (lib.all
              (key: assertionFired
                (evalNode [ hostName { plexsphere.node.sshAuthorizedKeys = [ key ]; } ])
                "sshAuthorizedKeys")
              [
                # An authorized_keys options prefix. ssh-keygen -l skips over
                # it and fingerprints the key behind it; no pattern here
                # allows a field in front of the key type.
                ("restrict,command=\"true\" " + placeholderKey)
                # A 1024-bit RSA key, generated for this check. ssh-keygen -l
                # prints it as any other; the {356,} blob floor of the ssh-rsa
                # pattern, which is that of a 2048-bit key, is what rejects it.
                "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQCw3E2593kkX4ILCt+BbJ44RBInW2oQ9lWu58VDl61YKf6Lg2Rb9lx6f5IcRMtgjnNxC1N/LNiXQFVwmUtZ2XUQxpuhIrws+4QLYbq3+RGA0U1yE8uiUq3ljAA9YiFOsTdIu2jZbNInBGBS5eJlAgE+wyOb2W7DKrwBFjjtzTHkow== weak@example.invalid"
                # A CRLF line ending, which a self-hosted authorized_keys file
                # can carry and read -r leaves in place: carriage return is
                # not in IFS. ssh-keygen -l fingerprints the line and prints
                # "no comment"; the patterns here match the whole line.
                (commentless + "\r")
                # A run of blanks where the patterns spell exactly one space.
                ("ssh-ed25519  " + lib.removePrefix "ssh-ed25519 " placeholderKey)
              ])
            "plexsphere.node.sshAuthorizedKeys must reject an authorized_keys options prefix, an RSA key below 2048 bits, a CRLF line ending and a run of blanks between the fields — the four shapes ssh-keygen -l fingerprints without complaint, which the installer has to reject or normalize at the prompt on this option's behalf";

        # hostName has no default because k3s derives the Kubernetes node name
        # from it, and two nodes sharing one contend for the same Node object.
        hostname-required = passIf "hostname-required"
          (evalThrows (evalNode [ sshKey ]).config.networking.hostName
            && !(evalThrows defaultNode.config.networking.hostName))
          "plexsphere.node.hostName must have no default";

        # plexd hooks forward only and never filters traffic addressed to the
        # host, so the node profile must leave the host packet filter standing
        # rather than hand it over — k3s' 6443, 10250 and 8472/udp would
        # otherwise face every attached network. The CNI devices get those two
        # ports and nothing else: a trusted interface accepts every port, so
        # it would reopen sshd to every pod, and to anything able to inject a
        # VXLAN frame addressed to the node, in front of the port rules below.
        host-firewall-enabled = passIf "host-firewall-enabled"
          (let firewall = defaultNode.config.networking.firewall; in
          firewall.enable
          && !(lib.any (i: lib.elem i firewall.trustedInterfaces) [ "cni0" "flannel.1" ])
          && lib.all
            (i: firewall.interfaces.${i}.allowedTCPPorts == [ 6443 10250 ]
              && firewall.interfaces.${i}.allowedUDPPorts == [ ])
            [ "cni0" "flannel.1" ]
          && !(lib.elem 8472 firewall.allowedUDPPorts)
          && !(lib.any (p: lib.elem p firewall.allowedTCPPorts) [ 6443 10250 ]))
          "the node profile must keep networking.firewall enabled, leave the CNI devices untrusted, open only the apiserver and kubelet ports on them, and leave the k3s cluster ports closed everywhere else";

        # ProtectSystem=strict leaves sockets connectable — the read-only
        # remount rejects writes to regular files, directories and symlinks
        # only — and the unit runs as UID 0, so the paths that hand out
        # unsandboxed root have to be masked by name.
        plexd-sandbox-masks-root-paths = passIf "plexd-sandbox-masks-root-paths"
          (let masked = defaultNode.config.systemd.services.plexd.serviceConfig.InaccessiblePaths; in
          lib.all (p: lib.elem p masked) [
            "-/var/lib/rancher"
            "-/etc/rancher"
            "-/var/lib/kubelet"
            "-/run/systemd/private"
            "-/run/k3s"
            "-/run/containerd"
            "-/run/dbus"
          ])
          "the plexd unit must mask k3s' state and the root-equivalent sockets under /run";

        # plexd up probes the nftables backend over netlink before it
        # registers and exits when the probe is refused, so a unit that lost
        # CAP_NET_ADMIN or AF_NETLINK would never join the mesh and would
        # restart on that error forever.
        plexd-sandbox-grants-net-admin = passIf "plexd-sandbox-grants-net-admin"
          (let service = defaultNode.config.systemd.services.plexd.serviceConfig; in
          lib.all (key: lib.elem "CAP_NET_ADMIN" (lib.splitString " " service.${key}))
            [ "AmbientCapabilities" "CapabilityBoundingSet" ]
          && lib.elem "AF_NETLINK" service.RestrictAddressFamilies)
          "the plexd unit must keep CAP_NET_ADMIN and AF_NETLINK, or plexd fails its firewall pre-flight before registering";

        # With the firewall standing in front of plexd, the one port peers
        # dial has to stay open and follow a changed listen_port.
        plexd-wireguard-port-open = passIf "plexd-wireguard-port-open"
          (lib.elem 51820 defaultNode.config.networking.firewall.allowedUDPPorts
            && lib.elem 51999 (evalNode [
              hostName
              sshKey
              { services.plexd.settings.wireguard.listen_port = 51999; }
            ]).config.networking.firewall.allowedUDPPorts)
          "plexd's WireGuard port must be open and follow services.plexd.settings.wireguard.listen_port";

        # Session listeners bind the mesh IP on an ephemeral port, so the
        # range has to be open on the WireGuard interface. Open anywhere
        # else, or with the interface trusted outright, it would hand those
        # ports, or every port, to networks that are not the mesh.
        plexd-session-ports-open =
          let
            sessionRange = { from = 32768; to = 60999; };
            opensOn = host: iface:
              lib.elem sessionRange (host.config.networking.firewall.interfaces.${iface}.allowedTCPPortRanges or [ ]);
            firewall = defaultNode.config.networking.firewall;
            renamed = evalNode [
              hostName
              sshKey
              { services.plexd.settings.wireguard.interface_name = "mesh0"; }
            ];
          in
          passIf "plexd-session-ports-open"
            (opensOn defaultNode "plexd0"
              && !(lib.elem sessionRange firewall.allowedTCPPortRanges)
              && !(lib.elem "plexd0" firewall.trustedInterfaces)
              && opensOn renamed "mesh0"
              && !(opensOn renamed "plexd0"))
            "plexd's session port range must be open on the WireGuard interface only, follow services.plexd.settings.wireguard.interface_name, and leave that interface untrusted";

        # The README promises a host-level api.base_url beats the preset.
        plexd-settings-override =
          let
            host = evalNode [
              hostName
              sshKey
              { services.plexd.settings.api.base_url = "https://api.internal.example"; }
            ];
          in
          pkgs.runCommand "plexd-settings-override" { } ''
            rendered=${host.config.environment.etc."plexd/config.yaml".source}
            grep -q 'https://api.internal.example' "$rendered"
            ! grep -q 'api.plexsphere.com' "$rendered"
            touch $out
          '';

        # The session helper unit starts `plexd session-helper`, a subcommand
        # plexd gained in v0.8.0, and nothing else ties that unit to the
        # binary the package pins. A release without it answers `unknown
        # command "session-helper"` and exits 1, so a pin moved back or to a
        # build that dropped the helper fails here, not on the first session
        # a node is asked to serve.
        plexd-package-has-session-helper =
          pkgs.runCommand "plexd-package-has-session-helper" { } ''
            ${defaultNode.config.services.plexd.package}/bin/plexd session-helper --help > /dev/null
            touch $out
          '';

        # plexd refuses to start on a malformed session_signing_public_key and
        # restarts on it forever, so the option has to turn every shape plexd
        # rejects into an evaluation error: no padding, the URL-safe
        # alphabet, the hex a key is also commonly written in, and the
        # trailing newline of a key read from a file. An unset key must leave
        # the rendered file of every existing node as it was, and a second,
        # different key in settings must not win silently. The key is a
        # throwaway generated for this repository.
        plexd-session-signing-key-option =
          let
            key = "4U1YI+YiHKMzeEXxk10y3mdBhsYxwmSrV9n3RSlmTRg=";
            withKey = k: evalNode [
              hostName
              sshKey
              { services.plexd.sessionSigningPublicKey = k; }
            ];
            conflicting = evalNode [
              hostName
              sshKey
              {
                services.plexd.sessionSigningPublicKey = key;
                services.plexd.settings.tunnel.session_signing_public_key =
                  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
              }
            ];
          in
          passIf "plexd-session-signing-key-option"
            ((withKey key).config.services.plexd.settings.tunnel.session_signing_public_key == key
              && !(defaultNode.config.services.plexd.settings ? tunnel)
              && lib.all (k: evalThrows (withKey k).config.services.plexd.sessionSigningPublicKey) [
                ""
                "4U1YI+YiHKMzeEXxk10y3mdBhsYxwmSrV9n3RSlmTRg"
                "4U1YI-YiHKMzeEXxk10y3mdBhsYxwmSrV9n3RSlmTRg="
                "e14d5823e6221ca3337845f1935d32de674186c631c264ab57d9f74529664d18"
                (key + "\n")
              ]
              && evalThrows conflicting.config.services.plexd.settings.tunnel.session_signing_public_key)
            "services.plexd.sessionSigningPublicKey must reach tunnel.session_signing_public_key when set, add no tunnel block when unset, reject anything but a 44-character standard-base64 key, and conflict with a different settings value";

        # Without the socket plexd runs the session helper as its own child,
        # inside its sandbox, and every shell fails to switch users. The
        # helper is useful only outside that sandbox, so no directive of
        # plexd's unit may reach it, and restarting an instance on switch
        # would only kill the shell it serves. plexd has to pull the socket
        # in, start after it, and be able to connect(): a mask on the path
        # would bring the child back, with no error but plexd's warning.
        plexd-session-helper-units =
          let
            socket = defaultNode.config.systemd.sockets.plexd-session-helper;
            helper = defaultNode.config.systemd.services."plexd-session-helper@";
            plexd = defaultNode.config.systemd.services.plexd;
          in
          passIf "plexd-session-helper-units"
            (socket.listenStreams == [ "/run/plexd-session-helper.sock" ]
              && lib.elem "sockets.target" socket.wantedBy
              && (socket.socketConfig.Accept or false) == true
              && (socket.socketConfig.SocketMode or null) == "0600"
              && (socket.socketConfig.SocketUser or null) == "root"
              && (socket.socketConfig.SocketGroup or null) == "root"
              && (helper.serviceConfig.ExecStart or null)
                == "${defaultNode.config.services.plexd.package}/bin/plexd session-helper --config /etc/plexd/config.yaml"
              && helper.restartIfChanged == false
              && lib.all (k: !(helper.serviceConfig ? ${k}))
                (lib.subtractLists [ "Type" "ExecStart" ] (lib.attrNames plexd.serviceConfig))
              && lib.elem "plexd-session-helper.socket" plexd.wants
              && lib.elem "plexd-session-helper.socket" plexd.after
              && !(lib.any (lib.hasInfix "plexd-session-helper") plexd.serviceConfig.InaccessiblePaths))
            "the plexd module must declare plexd-session-helper.socket (Accept=yes, 0600 root) and an unsandboxed plexd-session-helper@.service that runs the pinned plexd's session-helper with /etc/plexd/config.yaml and is never restarted on switch, and plexd must want, order after and reach the socket";

        # The session helper trusts the key in /etc/plexd/config.yaml or the
        # one it pinned at /etc/plexd/session-signing-key, and both are only
        # a trust anchor while plexd cannot write /etc. ConfigurationDirectory
        # or ReadWritePaths would reopen it to plexd without touching
        # ProtectSystem, so all three are pinned.
        plexd-session-anchor-read-only =
          let service = defaultNode.config.systemd.services.plexd.serviceConfig; in
          passIf "plexd-session-anchor-read-only"
            (lib.elem (service.ProtectSystem or null) [ "full" "strict" ]
              && !(service ? ReadWritePaths)
              && !(service ? ConfigurationDirectory))
            "plexd's unit must keep /etc read-only, or plexd could replace the session helper's pinned signing key at /etc/plexd/session-signing-key";

        # The sibling provisioning paths of issues #3 and #5 inherit this
        # module, so a later relaxation of either half of the posture would
        # reach them without a word: an sshd setting flipped back would carry
        # the console credential onto the network, and a hash assigned to
        # users.users.root.hashedPassword instead of the file would land it in
        # the world-readable store. Pin both halves, and the untouched default.
        password-file-stays-console-only =
          let
            host = evalNode [
              hostName
              sshKey
              { plexsphere.node.hashedPasswordFile = "/etc/plexsphere/root-password-hash"; }
            ];
            sshd = host.config.services.openssh.settings;
            root = host.config.users.users.root;
          in
          passIf "password-file-stays-console-only"
            (sshd.PasswordAuthentication == false
              && sshd.KbdInteractiveAuthentication == false
              && sshd.PermitRootLogin == "prohibit-password"
              && root.hashedPasswordFile == "/etc/plexsphere/root-password-hash"
              && root.hashedPassword == null
              && defaultNode.config.users.users.root.hashedPasswordFile == null)
            "plexsphere.node.hashedPasswordFile must reach users.users.root.hashedPasswordFile, leave users.users.root.hashedPassword unset so no hash reaches the Nix store, stay unset when the option is not given, and must not relax the sshd posture that confines the credential to the console";

        # buildcatrust skips a key block without a word and trusts every
        # certificate in an entry, so what reaches the world-readable store
        # and the bundle is decided by the assertion alone. Each refused
        # entry is a mistake an operator makes: an empty string, the URL
        # instead of the file, a bundle, a key pasted along, a key alone, a
        # half-substituted body, a paste cut short before its END line, and
        # the tail of a key whose BEGIN line the paste lost. The surrounding
        # blank lines and the CRLF line endings of a file read with
        # builtins.readFile are not one of them, nor is the missing final
        # newline of the installer's entry, and the list reaches
        # security.pki.certificates as given. Unset, nothing changes for an
        # existing node.
        extra-ca-certificates-validated =
          let
            withCA = ca: evalNode [
              hostName
              sshKey
              { plexsphere.node.extraCACertificates = [ ca ]; }
            ];
            halfSubstituted = lib.concatStringsSep "\n"
              (lib.imap0 (i: line: if i == 2 then "REPLACE-ME!" else line)
                (lib.splitString "\n" placeholderCA));
          in
          passIf "extra-ca-certificates-validated"
            (defaultNode.config.security.pki.certificates == [ ]
              && lib.all
                (ca:
                  let host = withCA ca; in
                  !(assertionFired host "extraCACertificates")
                  && host.config.security.pki.certificates == [ ca ])
                [
                  placeholderCA
                  ("\n" + placeholderCA + "\n\n")
                  (lib.replaceStrings [ "\n" ] [ "\r\n" ] placeholderCA)
                  installerCA
                ]
              && lib.all (ca: assertionFired (withCA ca) "extraCACertificates") [
                ""
                "http://ca.192-0-2-1.nip.io/lab-ca.crt"
                (placeholderCA + placeholderCA)
                (placeholderCA + fakeKey)
                fakeKey
                halfSubstituted
                (lib.removeSuffix "-----END CERTIFICATE-----\n" placeholderCA)
                (placeholderCA + "AAAA\n-----END PRIVATE KEY-----\n")
              ])
            "plexsphere.node.extraCACertificates must default to no certificate, pass one PEM certificate per entry to security.pki.certificates unchanged, also with CRLF line endings and without a final newline, and fail the assertion on an empty entry, a URL, two certificates, a certificate with a key, a key alone, a body that is not base64, a certificate cut short and a key's tail behind a certificate";

        # The check above stops at the option's value. This one follows it
        # into the file plexd, k3s and curl read: the bundle of a node that
        # sets the option verifies the check CA, whether its entry ends in a
        # newline like a file or not like the installer's, and the bundle of
        # one that does not keeps refusing it.
        extra-ca-certificates-trusted =
          let
            bundle = host: host.config.environment.etc."ssl/certs/ca-certificates.crt".source;
            trusting = ca: evalNode [
              hostName
              sshKey
              { plexsphere.node.extraCACertificates = [ ca ]; }
            ];
          in
          pkgs.runCommand "extra-ca-certificates-trusted" { nativeBuildInputs = [ pkgs.openssl ]; } ''
            printf '%s' ${lib.escapeShellArg placeholderCA} > ca.crt
            openssl verify -no_check_time -CAfile ${bundle (trusting placeholderCA)} ca.crt
            openssl verify -no_check_time -CAfile ${bundle (trusting installerCA)} ca.crt
            if openssl verify -no_check_time -CAfile ${bundle defaultNode} ca.crt; then
              echo "extra-ca-certificates-trusted: the bundle of a node without plexsphere.node.extraCACertificates trusts the check CA" >&2
              exit 1
            fi
            touch $out
          '';

        # Applying the layout is destructive and irreversible, so the target
        # must be named per host rather than defaulted.
        disk-device-required = passIf "disk-device-required"
          (evalThrows (lib.nixosSystem {
            system = "x86_64-linux";
            modules = [ self.nixosModules.disk ];
          }).config.disko.devices.disk.main.device)
          "plexsphere.disk.device must have no default";

        # The hybrid mode as the machine image turns it on, on a host that is
        # not the image, so a regression in the disk module is reported
        # against the module. grub.devices is pinned to exactly one entry:
        # disko adds the disk for the EF02 partition by itself, and a second
        # definition from modules/disk.nix would list it twice and make
        # install-grub.pl run grub-install twice on the same device.
        disk-bios-boot-hybrid =
          let
            host = ((exampleHost "x86_64-linux").extendModules {
              modules = [ { plexsphere.disk.biosBoot = true; } ];
            }).config;
            partitions = host.disko.devices.disk.main.content.partitions;
            loader = host.boot.loader;
          in
          passIf "disk-bios-boot-hybrid"
            (host.system.build.toplevel ? drvPath
              && partitions ? boot
              && partitions.boot.type == "EF02"
              && partitions.boot.size == "1M"
              && loader.grub.enable
              && loader.grub.efiSupport
              && loader.grub.efiInstallAsRemovable
              && loader.grub.devices == [ "/dev/disk/by-id/REPLACE-ME-example-disk" ]
              && loader.grub.configurationLimit == 5
              && !loader.systemd-boot.enable
              && !loader.efi.canTouchEfiVariables)
            "plexsphere.disk.biosBoot must add a 1M EF02 partition, install GRUB for BIOS and at the removable EFI path onto the disk disko names once, bound its generations, and turn systemd-boot and EFI variable writes off";

        # Every machine installed by the live USB installer or the SSH
        # takeover has the layout the default produces, and the next rebuild
        # of one applies whatever the default has become. A default that
        # drifted towards GRUB would swap the boot loader on those machines
        # without anyone asking for it.
        disk-bios-boot-default-unchanged =
          let
            host = (exampleHost "x86_64-linux").config;
            loader = host.boot.loader;
          in
          passIf "disk-bios-boot-default-unchanged"
            (!(host.disko.devices.disk.main.content.partitions ? boot)
              && loader.systemd-boot.enable
              && !loader.grub.enable
              && loader.efi.canTouchEfiVariables)
            "without plexsphere.disk.biosBoot the disk layout must keep systemd-boot, no BIOS boot partition, no GRUB and EFI variable writes";

        # aarch64 has no BIOS, and install-grub.pl dies on a non-nodev device
        # there because the aarch64 GRUB package has no i386-pc target. The
        # assertion turns that build-time failure into an evaluation error
        # that names the option.
        disk-bios-boot-rejected-on-aarch64 = passIf "disk-bios-boot-rejected-on-aarch64"
          (assertionFired
            ((exampleHost "aarch64-linux").extendModules {
              modules = [ { plexsphere.disk.biosBoot = true; } ];
            })
            "biosBoot")
          "plexsphere.disk.biosBoot must fail an assertion on an aarch64 node";

        # Evaluated, never deployed. As nixosConfigurations entries these
        # would be one `nixos-rebuild switch --flake …#example-x86_64` away
        # from installing a source-controlled root key on a real machine and
        # repointing its fileSystems at a device that does not exist — disko's
        # NixOS module defines fileSystems on activation without ever running
        # the destructive script that would create them. A second reason keeps
        # the output empty for the install targets too: nix flake check forces
        # config.system.build.toplevel of every nixosConfigurations entry, and
        # a target carrying no identity cannot be forced. Those live under
        # lib.installTargets, where disko-install reaches them through a flake
        # generated at ISO build time.
        example-hosts-evaluate = passIf "example-hosts-evaluate"
          (lib.all (system: (exampleHost system).config.system.build.toplevel ? drvPath)
            [ "x86_64-linux" "aarch64-linux" ])
          "the example host modules must evaluate on both architectures";

        # Both halves of why the install targets are safe to export, each
        # covering the other's blind spot. The absent output is what keeps
        # nix flake check from forcing a toplevel no identity-free target can
        # produce; the throwing hostName is what still makes a target useless
        # to whoever exports one anyway, on the day someone does.
        installer-target-not-deployable = passIf "installer-target-not-deployable"
          (!(self ? nixosConfigurations)
            && lib.all (target: evalThrows target.config.networking.hostName)
              (lib.attrValues self.lib.installTargets))
          "this flake must export no nixosConfigurations, and an install target must throw until the installer supplies plexsphere.node.hostName";

        # placeholderKey is committed to this repository and both example
        # hosts carry it. The install targets are the one place where a key
        # left in a module would be written to somebody's disk, so the list
        # they hand to sshd has to stay empty until the installer fills it.
        installer-target-carries-no-key = passIf "installer-target-carries-no-key"
          (lib.all (target: target.config.users.users.root.openssh.authorizedKeys.keys == [ ])
            (lib.attrValues self.lib.installTargets))
          "an install target must authorize no SSH key of its own";

        # system.stateVersion keys the backwards-compatible defaults nixpkgs
        # holds for stateful services, and a fresh install declares the
        # release it was installed under — which for the medium is whatever
        # nixpkgs.url resolves to. It stays a literal rather than becoming
        # config.system.nixos.release: a derived value would move on the next
        # bump, on installed nodes too, which is the drift the option exists
        # to prevent. So the coupling is pinned the way every other cross-file
        # string in this flake is pinned, rather than left to two lines that
        # happen to agree.
        installer-target-state-version = passIf "installer-target-state-version"
          (self.lib.installTargets.x86_64-linux.config.system.stateVersion == lib.trivial.release)
          "the install target's system.stateVersion must equal the release of the pinned nixpkgs; a fresh install declares the release it was installed under";

        # disko-install injects the collected identity by handing
        # extendModules a module it parsed from JSON (install-cli.nix:37-59),
        # so extending a target here exercises the mechanism the installer
        # actually uses. The device is the assertion that earns its keep: it
        # is what proves a plain definition beats the mkDefault placeholder,
        # which is the whole reason the placeholder is a mkDefault.
        installer-target-accepts-injected-identity =
          let
            installed = self.lib.installTargets.x86_64-linux.extendModules {
              modules = [
                {
                  plexsphere.node.hostName = "check-node";
                  plexsphere.node.sshAuthorizedKeys = [ placeholderKey ];
                  plexsphere.disk.device = "/dev/disk/by-id/check-disk";
                }
              ];
            };
          in
          passIf "installer-target-accepts-injected-identity"
            (installed.config.system.build.toplevel ? drvPath
              && installed.config.networking.hostName == "check-node"
              && installed.config.disko.devices.disk.main.device == "/dev/disk/by-id/check-disk")
            "an install target extended with a host name, an SSH key and a disk device must evaluate, take the injected host name, and let the plain device definition override the mkDefault placeholder";

        # The check above covers the three mandatory fields; these are the
        # three the script writes only when the operator answered the prompt,
        # and none is validated for it. An option renamed under
        # plexsphere.node throws — that is what the asserts force — but
        # services.plexd.settings is freeform (modules/plexd.nix:19-23), so a
        # jq path drifting from plexd's schema, .api.baseUrl for
        # .api.base_url, evaluates cleanly and leaves the node registering
        # against the preset instead: the operator answered the prompt, saw
        # the answer printed back, and gets a node talking to the wrong
        # control plane with no error anywhere. plexd-settings-override pins
        # the module half of this contract and stops one string short of the
        # installer half.
        installer-injects-optional-identity =
          let
            installed = self.lib.installTargets.x86_64-linux.extendModules {
              modules = [
                {
                  plexsphere.node.hostName = "check-node";
                  plexsphere.node.sshAuthorizedKeys = [ placeholderKey ];
                  plexsphere.disk.device = "/dev/disk/by-id/check-disk";
                  plexsphere.node.hashedPasswordFile = "/etc/plexsphere/root-password-hash";
                  services.plexd.settings.api.base_url = "https://api.internal.example";
                  plexsphere.node.extraCACertificates = [ placeholderCA ];
                }
              ];
            };
          in
          assert installed.config.users.users.root.hashedPasswordFile
            == "/etc/plexsphere/root-password-hash";
          assert installed.config.security.pki.certificates == [ placeholderCA ];
          pkgs.runCommand "installer-injects-optional-identity" { } ''
            grep -q -F -- '.plexsphere.node.hashedPasswordFile = "/etc/plexsphere/root-password-hash"' \
              ${self.packages.x86_64-linux.plexsphere-install}/bin/plexsphere-install
            grep -q -F -- '.services.plexd.settings.api.base_url = $url' \
              ${self.packages.x86_64-linux.plexsphere-install}/bin/plexsphere-install
            grep -q -F -- '.plexsphere.node.extraCACertificates = [$pem]' \
              ${self.packages.x86_64-linux.plexsphere-install}/bin/plexsphere-install
            rendered=${installed.config.environment.etc."plexd/config.yaml".source}
            grep -q 'https://api.internal.example' "$rendered"
            ! grep -q 'api.plexsphere.com' "$rendered"
            touch $out
          '';

        # The installer names the disko disk in a string, so renaming
        # disko.devices.disk.main in modules/disk.nix leaves it passing --disk
        # with a name the target no longer declares. disko-install demands one
        # mapping per declared disk and throws "No device passed for disk"
        # otherwise (install-cli.nix:13-19), so nothing is written — but the
        # failure lands on an operator who has already burned the medium and
        # answered every prompt. The assertion pins the declared name, the
        # grep pins the one that ships, and the rename fails in CI instead.
        installer-targets-declared-disk =
          assert lib.attrNames self.lib.installTargets.x86_64-linux.config.disko.devices.disk == [ "main" ];
          pkgs.runCommand "installer-targets-declared-disk" { } ''
            grep -q -F -- '--disk main' \
              ${self.packages.x86_64-linux.plexsphere-install}/bin/plexsphere-install
            touch $out
          '';

        # Three strings connected by interpolation alone: the generated flake
        # republishes lib.installTargets as nixosConfigurations out of this
        # flake's own source, and the installer asks that flake for one target
        # by name. Renaming a target or pointing the script at a different
        # flake breaks the chain without touching either end of it, and the
        # break only shows when disko-install fails to resolve the attribute
        # on a machine that has already been booted from the medium. The
        # attribute path the generated flake reads is a fourth link that no
        # interpolation carries: the assert below covers the output this flake
        # exports, which a typo inside that generated line leaves standing, so
        # the path is greped for as well.
        installer-flake-wiring =
          assert self.lib.installTargets ? x86_64-linux;
          pkgs.runCommand "installer-flake-wiring" { } ''
            grep -q nixosConfigurations \
              ${installTargetFlakeFor "x86_64-linux"}/flake.nix
            grep -q -F -- '${self}' \
              ${installTargetFlakeFor "x86_64-linux"}/flake.nix
            grep -q -F -- '.lib.installTargets' \
              ${installTargetFlakeFor "x86_64-linux"}/flake.nix
            grep -q -F -- '--flake ${installTargetFlakeFor "x86_64-linux"}#x86_64-linux' \
              ${self.packages.x86_64-linux.plexsphere-install}/bin/plexsphere-install
            touch $out
          '';

        # The pre-flight probe decides whether a provisioning network that
        # reaches a substituter and nothing else is caught before the first
        # prompt or after every one of them, and the README is where an
        # operator reads which names to let through an egress filter. Nothing
        # but agreement ties the two lists together, and they were wrong
        # together once: both named github.com, which nix never asks for —
        # with flake.lock pinning a revision it resolves no ref, so each input
        # costs one tarball fetch addressed to api.github.com and redirected
        # to codeload.github.com. Pin the names in both places, so a probe
        # that gains or loses a host without the README following fails here
        # rather than on somebody's provisioning network.
        installer-network-preflight-hosts =
          pkgs.runCommand "installer-network-preflight-hosts" { } ''
            for host in cache.nixos.org api.github.com codeload.github.com; do
              grep -q -F -- "$host" \
                ${self.packages.x86_64-linux.plexsphere-install}/bin/plexsphere-install
              grep -q -F -- "$host" ${./README.md}
            done
            touch $out
          '';

        # Only the x86_64 image is within reach of a build here: the aarch64
        # one needs an aarch64 builder, which CI does not have. Evaluation is
        # what both architectures share, and it is where every module-level
        # error lives — a mistyped option, a volume ID over the 32-byte ISO
        # 9660 limit, an installer package the medium cannot instantiate.
        # Forcing drvPath alone stops at WHNF, exactly as
        # example-hosts-evaluate does, so the check stays cheap.
        installer-iso-evaluates = passIf "installer-iso-evaluates"
          (lib.all (system: installerSystems.${system}.config.system.build.isoImage ? drvPath)
            [ "x86_64-linux" "aarch64-linux" ])
          "the installer medium must evaluate on both architectures";

        # The check above forces the image and nothing in it, so dropping the
        # systemPackages entry from installerSystem — in a refactor, a merge,
        # a split of the ISO definition — leaves every check green and CI
        # still printing an image size. The medium boots, the console says to
        # run 'sudo plexsphere-install', and the command is not there. That
        # lands on an operator who has already burnt the stick, so pin both
        # halves: the script is on the medium, and the help line names it.
        installer-medium-ships-the-script = passIf "installer-medium-ships-the-script"
          (lib.all
            (system:
              let
                script = plexsphereInstallFor system;
                medium = installerSystems.${system}.config;
              in
              lib.elem script medium.environment.systemPackages
              && lib.hasInfix script.name medium.services.getty.helpLine)
            [ "x86_64-linux" "aarch64-linux" ])
          "the installer medium must ship plexsphere-install and name it on the console";

        # The banner reaches a console through an import of
        # modules/banner.nix, one in modules/installer.nix and one in
        # modules/node.nix, and dropping either breaks nothing: the machine
        # greets with the stock NixOS welcome line and every other check
        # stays green. So the greeting is pinned on everything an operator
        # boots — the medium, the target the medium installs and the machine
        # image. The greeting line forces no identity, which is why an
        # install target can be asked for it without a host name.
        consoles-show-the-banner = passIf "consoles-show-the-banner"
          (lib.all
            (system: lib.all
              (host: lib.hasPrefix "+---" host.config.services.getty.greetingLine)
              [
                installerSystems.${system}
                self.lib.installTargets.${system}
                imageSystems.${system}
              ])
            [ "x86_64-linux" "aarch64-linux" ])
          "the installer medium, the node it installs and the machine image must greet with the PLEXSPHERE banner on the console";

        # The template ships with an empty key list, so this supplies one the
        # way an operator's edit to node.nix would; every other value is the
        # template's own. Forcing the toplevel runs the module assertions on
        # both architectures, and stateVersion is held to the release of the
        # nixpkgs the template follows, as installer-target-state-version holds
        # it for the live USB path.
        takeover-template-evaluates = passIf "takeover-template-evaluates"
          (lib.all
            (system:
              let host = (takeoverHost system [ sshKey ]).config; in
              host.system.build.toplevel ? drvPath
              && host.networking.hostName == "plex-node-01"
              && host.nixpkgs.hostPlatform.system == system
              && host.disko.devices.disk.main.device == "/dev/disk/by-id/REPLACE-ME"
              && host.users.users.root.openssh.authorizedKeys.keys == [ placeholderKey ]
              && host.users.users.root.hashedPasswordFile == null
              && host.system.stateVersion == lib.trivial.release)
            [ "x86_64-linux" "aarch64-linux" ])
          "the takeover template must evaluate on both architectures once a key is supplied, take its identity from node.nix, and declare the release of the pinned nixpkgs as its stateVersion";

        # No key can ship in the template: a real one would be authorized on
        # every node taken over with it, which is the reason placeholderKey
        # stays out of every deployable output, and a visibly broken one would
        # fail the same assertion with a less direct message. What has to hold
        # instead is that an operator who never fills the list in gets the
        # assertion rather than a node nobody can log into.
        takeover-template-rejects-unedited-key = passIf "takeover-template-rejects-unedited-key"
          (assertionFired (takeoverHost "x86_64-linux" [ ]) "sshAuthorizedKeys")
          "the takeover template must fail the sshAuthorizedKeys assertion until the operator adds a key";

        # The two checks above substitute self for the template's
        # plexsphere-node input, so its URL is the one string in the template
        # that no evaluation here covers. The README commands are what an
        # operator types, and nothing but agreement ties them to the template.
        # Pin both sides, so a renamed configuration or a dropped flag fails
        # here rather than on a machine whose disk nixos-anywhere has already
        # partitioned. The --flake pattern carries the line continuation of
        # the nixos-anywhere command, because the README passes the same
        # --flake .#node-x86_64 to nixos-rebuild as well, and a bare pattern
        # would keep passing when only the takeover command drifts.
        takeover-docs-match-the-template =
          pkgs.runCommand "takeover-docs-match-the-template" { } ''
            for pattern in \
                github:plexsphere/plexsphere-node \
                nixosModules.disk \
                nixosModules.node \
                ./node.nix \
                hardware-configuration.nix; do
              grep -q -F -- "$pattern" ${./templates/node/flake.nix}
            done
            for pattern in \
                'nix flake init -t github:plexsphere/plexsphere-node#node' \
                '--flake .#node-x86_64 \' \
                '--generate-hardware-config nixos-generate-config ./hardware-configuration.nix' \
                '--build-on remote' \
                '--extra-files' \
                '--copy-host-keys'; do
              grep -q -F -- "$pattern" ${./README.md}
            done
            touch $out
          '';

        # CI builds the x86_64 image and only evaluates the aarch64 one, as it
        # does for the installer medium, so evaluation is what both
        # architectures share. diskoImages ? drvPath alone stops at the WHNF
        # of the builder derivation and never reaches the system it installs;
        # forcing the toplevel as well is what runs the module assertions.
        image-evaluates = passIf "image-evaluates"
          (lib.all
            (system:
              let image = imageSystems.${system}.config; in
              image.system.build.toplevel ? drvPath
              && image.system.build.diskoImages ? drvPath)
            [ "x86_64-linux" "aarch64-linux" ])
          "the machine image must evaluate on both architectures";

        # One image boots every instance made from it, so whatever identity it
        # carries, every one of those nodes shares: a host name puts them all
        # on one k3s Node object, a root key or password lets its holder into
        # all of them, and a CA certificate built in would be trusted by every
        # one of them. cloud-init supplies the identity at first boot, and the
        # user-data the certificates.
        image-carries-no-identity = passIf "image-carries-no-identity"
          (lib.all
            (system:
              let image = imageSystems.${system}.config; in
              image.networking.hostName == ""
              && image.users.users.root.openssh.authorizedKeys.keys == [ ]
              && image.users.users.root.hashedPasswordFile == null
              && image.users.users.root.hashedPassword == null
              && image.security.pki.certificates == [ ])
            [ "x86_64-linux" "aarch64-linux" ])
          "the machine image must carry no host name, no root SSH key, no root password and no extra CA certificate";

        # The ordering is what keeps k3s from registering its Node object under
        # the host name from before cloud-init, and plexd from starting before
        # /etc/plexd/bootstrap-token exists. A wants or requires in its place
        # would be worse than none: when no datasource is found,
        # cloud-final.service never starts, and a unit that depends on it
        # would never start either.
        image-waits-for-cloud-init = passIf "image-waits-for-cloud-init"
          (lib.all
            (system:
              let
                image = imageSystems.${system}.config;
                pullsInCloudInit = lib.any (lib.hasPrefix "cloud-");
              in
              image.services.cloud-init.enable
              && image.services.cloud-init.network.enable
              && image.networking.useNetworkd
              && lib.all
                (name:
                  let unit = image.systemd.services.${name}; in
                  lib.elem "cloud-final.service" unit.after
                  && !(pullsInCloudInit unit.wants)
                  && !(pullsInCloudInit unit.requires))
                [ "k3s" "plexd" ])
            [ "x86_64-linux" "aarch64-linux" ])
          "the machine image must enable cloud-init with networkd and order k3s and plexd after cloud-final.service without wanting or requiring any cloud-init unit";

        # The image trusts whatever plexsphere-ca-trust appends, system-wide
        # and for every name, so the script is run here on the files an
        # operator gets wrong: a key pasted along, two certificates, text
        # that is none, and the tail of a key whose BEGIN line the paste
        # lost, which passes the one-block rule and must still not be copied.
        # The subject is text the certificate's issuer chose, so its line
        # feeds and C1 controls (U+009B is CSI on the Linux console) reach
        # the journal escaped; the file name is text the user-data chose, so
        # it reaches it quoted by printf %q, its control bytes escaped, and
        # so does the name of an entry that is a directory: no line printed
        # holds a byte outside printable ASCII.
        # A skipped file fails the unit and leaves every valid one trusted;
        # a directory with nothing to trust leaves the system bundle as it
        # is; an unreadable system bundle leaves the previous output alone.
        # The broker's bundle file, the fourth argument, may hold several
        # certificates and sits beside the directory's files, but it is
        # trusted whole or not at all: a key, a block that is no
        # certificate, a block without its END line, or a directory in its
        # place skips all of it, the valid certificate in front included.
        # A key's tail behind its certificates is dropped, as in a
        # directory file, and so is text in front of and between them,
        # such as the subject lines openssl s_client -showcerts writes. A
        # missing, empty or blank bundle file is a document without a
        # bundle and leaves the system bundle as it is; a file of bytes a
        # UTF-8 locale cannot decode is not blank and is skipped.
        # The derivation is the one the image starts.
        ca-trust-script =
          let
            trust = imageSystems.x86_64-linux.pkgs.callPackage ./packages/plexsphere-ca-trust.nix { };
          in
          pkgs.runCommand "ca-trust-script" { nativeBuildInputs = [ pkgs.openssl ]; } ''
            bundle=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            compose() {
              rc=0
              ${trust}/bin/plexsphere-ca-trust "$@" > stdout 2> stderr || rc=$?
            }
            fail() {
              echo "ca-trust-script: $1" >&2
              exit 1
            }

            printf '%s' ${lib.escapeShellArg placeholderCA} > ca.crt
            fingerprint=$(openssl x509 -in ca.crt -noout -fingerprint -sha256)

            mkdir mixed
            cp ca.crt mixed/good.crt
            printf '%s' ${lib.escapeShellArg (placeholderCA + fakeKey)} > mixed/keyed.crt
            printf '%s' ${lib.escapeShellArg (placeholderCA + placeholderCA)} > mixed/two.crt
            echo 'not a certificate' > mixed/garbage.crt
            compose "$bundle" mixed mixed.out
            [ "$rc" = 1 ] || fail "a directory with a file to skip must exit 1, not $rc"
            grep -q -x -F -- \
              "trusting mixed/good.crt: subject=CN=plexsphere-node check CA sha256 Fingerprint=''${fingerprint#*=}" \
              stdout || fail "stdout must name mixed/good.crt with its subject and fingerprint"
            for name in keyed two garbage; do
              grep -q -F -- "skipping mixed/$name.crt: " stderr ||
                fail "stderr must name mixed/$name.crt as skipped"
              if grep -q -F -- "mixed/$name.crt" stdout; then
                fail "mixed/$name.crt must not be reported as trusted"
              fi
            done
            openssl verify -no_check_time -CAfile mixed.out ca.crt ||
              fail "the composed bundle must verify the certificate of mixed/good.crt"
            if grep -q 'PRIVATE KEY' mixed.out; then
              fail "the composed bundle must hold no private key"
            fi
            [ "$(grep -c -e '-----BEGIN ' mixed.out)" = $(($(grep -c -e '-----BEGIN ' "$bundle") + 1)) ] ||
              fail "the composed bundle must hold the system bundle and one certificate more"
            [ "$(stat -c %a mixed.out)" = 644 ] || fail "the composed bundle must be mode 644"

            mkdir tail
            printf '%s' ${lib.escapeShellArg (placeholderCA + "AAAA\n-----END PRIVATE KEY-----\n")} > tail/tail.crt
            compose "$bundle" tail tail.out
            [ "$rc" = 0 ] || fail "a certificate with a key's tail behind it must be trusted, not exit $rc"
            openssl verify -no_check_time -CAfile tail.out ca.crt ||
              fail "the composed bundle must verify the certificate of tail/tail.crt"
            if grep -q 'PRIVATE KEY' tail.out; then
              fail "only openssl's encoding of the certificate may be appended, never the rest of the file"
            fi

            mkdir crafted
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
              -keyout /dev/null -days 1 -utf8 -subj "/CN=lab$(printf '\n\302\233')2J" \
              -out crafted/subject.crt
            cp ca.crt "crafted/$(printf 'a\033[2Jb').crt"
            cp ca.crt "crafted/$(printf 'e\t\n\302\233f').crt"
            echo 'not a certificate' > "crafted/$(printf 'c\033[2Jd').crt"
            echo 'not a certificate' > "crafted/$(printf 'g\t\n\302\233h').crt"
            mkdir "crafted/$(printf 'i\033[2Jj').crt"
            compose "$bundle" crafted crafted.out
            grep -q -x -F -- \
              "trusting crafted/subject.crt: subject=CN=lab\\0A\\C2\\9B2J $(openssl x509 -in crafted/subject.crt -noout -fingerprint -sha256)" \
              stdout || fail "a subject's line feed and C1 controls must be printed escaped, followed by the fingerprint"
            grep -q -F -- "trusting \$'crafted/a\\E[2Jb.crt': " stdout ||
              fail "the name of a trusted file must be printed with its control bytes escaped"
            grep -q -F -- "skipping \$'crafted/c\\E[2Jd.crt': " stderr ||
              fail "the name of a skipped file must be printed with its control bytes escaped"
            grep -q -F -- "trusting \$'crafted/e\\t\\n\\302\\233f.crt': " stdout ||
              fail "the name of a trusted file must be printed with its tabs, line feeds and C1 controls escaped"
            grep -q -F -- "skipping \$'crafted/g\\t\\n\\302\\233h.crt': " stderr ||
              fail "the name of a skipped file must be printed with its tabs, line feeds and C1 controls escaped"
            grep -q -F -- "skipping \$'crafted/i\\E[2Jj.crt': " stderr ||
              fail "a directory with a .crt name must be skipped and named with its control bytes escaped"
            if LC_ALL=C grep -q '[^[:print:]]' stdout stderr; then
              fail "nothing printed may hold a byte outside printable ASCII"
            fi

            mkdir empty pem
            cp ca.crt pem/good.pem
            for directory in empty missing pem; do
              compose "$bundle" "$directory" "$directory.out"
              [ "$rc" = 0 ] || fail "$directory: nothing to trust must exit 0, not $rc"
              cmp "$bundle" "$directory.out" || fail "$directory: the output must be the system bundle"
            done

            systemCount=$(grep -c -e '-----BEGIN ' "$bundle")
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
              -keyout /dev/null -days 1 -subj '/CN=plexsphere-node check bundle CA' \
              -out second.crt
            secondLine="$(openssl x509 -in second.crt -noout -subject -nameopt RFC2253) $(openssl x509 -in second.crt -noout -fingerprint -sha256)"

            cat ca.crt second.crt > bundle.crt
            compose "$bundle" empty bundle.out bundle.crt
            [ "$rc" = 0 ] || fail "a bundle file of two certificates must be trusted, not exit $rc"
            grep -q -x -F -- \
              "trusting bundle.crt certificate 1: subject=CN=plexsphere-node check CA sha256 Fingerprint=''${fingerprint#*=}" \
              stdout || fail "stdout must name the first certificate of bundle.crt with its subject and fingerprint"
            grep -q -x -F -- "trusting bundle.crt certificate 2: $secondLine" stdout ||
              fail "stdout must name the second certificate of bundle.crt with its subject and fingerprint"
            openssl verify -no_check_time -CAfile bundle.out ca.crt second.crt ||
              fail "the composed bundle must verify both certificates of bundle.crt"
            [ "$(grep -c -e '-----BEGIN ' bundle.out)" = $((systemCount + 2)) ] ||
              fail "the composed bundle must hold the system bundle and both certificates of bundle.crt"

            mkdir single
            cp ca.crt single/good.crt
            cp second.crt second-only.crt
            compose "$bundle" single single.out second-only.crt
            [ "$rc" = 0 ] || fail "a directory file and a bundle file must both be trusted, not exit $rc"
            grep -q -x -F -- \
              "trusting single/good.crt: subject=CN=plexsphere-node check CA sha256 Fingerprint=''${fingerprint#*=}" \
              stdout || fail "stdout must name single/good.crt beside the bundle file"
            grep -q -x -F -- "trusting second-only.crt certificate 1: $secondLine" stdout ||
              fail "stdout must name the certificate of second-only.crt beside the directory file"
            [ "$(grep -c -e '-----BEGIN ' single.out)" = $((systemCount + 2)) ] ||
              fail "the composed bundle must hold the system bundle, the directory file and the bundle file"

            printf '%s' ${lib.escapeShellArg (placeholderCA + fakeKey)} > bundle-keyed.crt
            printf '%s' ${lib.escapeShellArg (placeholderCA + "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")} > bundle-body.crt
            printf '%s' ${lib.escapeShellArg (lib.removeSuffix "-----END CERTIFICATE-----\n" placeholderCA)} > bundle-cut.crt
            mkdir bundle-dir.crt
            for name in bundle-keyed bundle-body bundle-cut bundle-dir; do
              compose "$bundle" empty "$name.out" "$name.crt"
              [ "$rc" = 1 ] || fail "$name.crt must be skipped with exit 1, not $rc"
              grep -q -x -F -- \
                "skipping $name.crt: it must hold one or more PEM certificates and nothing else" \
                stderr || fail "stderr must name $name.crt as skipped"
              if grep -q -F -- "trusting $name.crt" stdout; then
                fail "no certificate of $name.crt may be reported as trusted"
              fi
              if grep -q 'PRIVATE KEY' "$name.out"; then
                fail "the composed bundle must hold no private key from $name.crt"
              fi
              [ "$(grep -c -e '-----BEGIN ' "$name.out")" = "$systemCount" ] ||
                fail "$name.crt must be skipped whole, its valid certificate included"
            done

            printf '%s' ${lib.escapeShellArg (placeholderCA + "AAAA\n-----END PRIVATE KEY-----\n")} > bundle-tail.crt
            compose "$bundle" empty bundle-tail.out bundle-tail.crt
            [ "$rc" = 0 ] || fail "a bundle file with a key's tail behind its certificate must be trusted, not exit $rc"
            grep -q -F -- "trusting bundle-tail.crt certificate 1: " stdout ||
              fail "stdout must name the certificate of bundle-tail.crt"
            openssl verify -no_check_time -CAfile bundle-tail.out ca.crt ||
              fail "the composed bundle must verify the certificate of bundle-tail.crt"
            if grep -q 'PRIVATE KEY' bundle-tail.out; then
              fail "only openssl's encoding of each certificate may be appended, never the rest of the bundle file"
            fi

            { echo 'plexsphere-node bundle preamble'; cat ca.crt; echo 'plexsphere-node bundle interlude'; cat second.crt; } > bundle-text.crt
            compose "$bundle" empty bundle-text.out bundle-text.crt
            [ "$rc" = 0 ] || fail "a bundle file with text in front of and between its certificates must be trusted, not exit $rc"
            grep -q -x -F -- \
              "trusting bundle-text.crt certificate 1: subject=CN=plexsphere-node check CA sha256 Fingerprint=''${fingerprint#*=}" \
              stdout || fail "stdout must name the first certificate of bundle-text.crt"
            grep -q -x -F -- "trusting bundle-text.crt certificate 2: $secondLine" stdout ||
              fail "stdout must name the second certificate of bundle-text.crt"
            openssl verify -no_check_time -CAfile bundle-text.out ca.crt second.crt ||
              fail "the composed bundle must verify both certificates of bundle-text.crt"
            [ "$(grep -c -e '-----BEGIN ' bundle-text.out)" = $((systemCount + 2)) ] ||
              fail "the composed bundle must hold the system bundle and both certificates of bundle-text.crt"
            if grep -q -F 'plexsphere-node bundle' bundle-text.out; then
              fail "the text around the certificates of bundle-text.crt must not be appended"
            fi

            cp ca.crt "$(printf 'k\033[2Jl').crt"
            compose "$bundle" empty escaped.out "$(printf 'k\033[2Jl').crt"
            grep -q -F -- "trusting \$'k\\E[2Jl.crt' certificate 1: " stdout ||
              fail "the name of a trusted bundle file must be printed with its control bytes escaped"
            cat stdout stderr > escaped.log
            echo 'not a certificate' > "$(printf 'm\033[2Jn').crt"
            compose "$bundle" empty escaped.out "$(printf 'm\033[2Jn').crt"
            grep -q -F -- "skipping \$'m\\E[2Jn.crt': " stderr ||
              fail "the name of a skipped bundle file must be printed with its control bytes escaped"
            if LC_ALL=C grep -q '[^[:print:]]' escaped.log stdout stderr; then
              fail "nothing printed about a bundle file may hold a byte outside printable ASCII"
            fi

            : > bundle-empty.crt
            printf '\n \n' > bundle-blank.crt
            for name in no-such-bundle bundle-empty bundle-blank; do
              compose "$bundle" empty "$name.out" "$name.crt"
              [ "$rc" = 0 ] || fail "$name.crt: no bundle must exit 0, not $rc"
              if [ -s stdout ] || [ -s stderr ]; then
                fail "$name.crt: no bundle must print no trusting and no skipping line"
              fi
              cmp "$bundle" "$name.out" || fail "$name.crt: the output must be the system bundle"
            done

            printf '\377\376\n' > bundle-bytes.crt
            rc=0
            LC_ALL=C.UTF-8 ${trust}/bin/plexsphere-ca-trust "$bundle" empty bundle-bytes.out bundle-bytes.crt > stdout 2> stderr || rc=$?
            [ "$rc" = 1 ] || fail "a bundle file of bytes a UTF-8 locale cannot decode must be skipped with exit 1, not $rc"
            grep -q -x -F -- "skipping bundle-bytes.crt: it must hold one or more PEM certificates and nothing else" stderr ||
              fail "stderr must name bundle-bytes.crt as skipped"

            echo kept > kept.out
            cp kept.out kept.ref
            compose ./no-such-bundle mixed kept.out
            [ "$rc" != 0 ] || fail "an unreadable system bundle must exit non-zero"
            cmp kept.ref kept.out || fail "an unreadable system bundle must leave the output alone"

            compose "$bundle" mixed
            [ "$rc" = 2 ] || fail "a wrong argument count must exit 2, not $rc"
            compose "$bundle" empty five.out bundle.crt extra
            [ "$rc" = 2 ] || fail "five arguments must exit 2, not $rc"

            touch $out
          '';

        # The script above matters only if the image runs it and reads its
        # output. All three bundle paths have to lead to the composed file,
        # or whatever reads the one left behind ignores the user-data's
        # certificates; the tmpfiles seed has to exist, or a boot whose
        # compose fails leaves every TLS client without roots; and the unit
        # has to start after write_files and before cloud-init's later
        # stages, k3s and plexd, or plexd verifies the control plane against
        # the public roots alone. Ordering only: a wants or requires in
        # either direction would keep k3s and plexd down when the compose
        # fails, or the compose down when no datasource is found. Nodes that
        # are not the image keep the store bundle their configuration
        # declares. The install target is given a host name because reading
        # one environment.etc entry forces them all, /etc/hostname among
        # them.
        image-composes-ca-bundle =
          let
            composed = "/run/plexsphere/ca-bundle.crt";
            keepsStoreBundle = host:
              host.config.environment.etc."ssl/certs/ca-certificates.crt".source
                == host.config.security.pki.caBundle;
          in
          passIf "image-composes-ca-bundle"
            (lib.all
              (system:
                let
                  image = imageSystems.${system}.config;
                  trust = imageSystems.${system}.pkgs.callPackage ./packages/plexsphere-ca-trust.nix { };
                  tmpfiles = image.systemd.tmpfiles.settings."10-plexsphere-ca" or { };
                  unit = image.systemd.services.plexsphere-ca-trust;
                  dependsOn = service: names:
                    lib.any (name: lib.elem name (service.wants ++ service.requires)) names;
                in
                lib.all (path: image.environment.etc.${path}.source == composed)
                  [ "ssl/certs/ca-certificates.crt" "ssl/certs/ca-bundle.crt" "pki/tls/certs/ca-bundle.crt" ]
                && (tmpfiles.${composed}.C.argument or null) == image.security.pki.caBundle
                && tmpfiles ? "/run/plexsphere".d
                && unit.serviceConfig.ExecStart
                  == "${trust}/bin/plexsphere-ca-trust ${image.security.pki.caBundle} /etc/plexsphere/ca-certificates ${composed}"
                && lib.elem "multi-user.target" unit.wantedBy
                && lib.elem "cloud-init.service" unit.after
                && lib.all (name: lib.elem name unit.before)
                  [ "cloud-config.service" "cloud-final.service" "k3s.service" "plexd.service" ]
                && !(dependsOn unit
                  [ "cloud-init.service" "cloud-config.service" "cloud-final.service" "k3s.service" "plexd.service" ])
                && !(lib.any (name: dependsOn image.systemd.services.${name} [ "plexsphere-ca-trust.service" ])
                  [ "k3s" "plexd" ]))
              [ "x86_64-linux" "aarch64-linux" ]
            && keepsStoreBundle defaultNode
            && keepsStoreBundle (self.lib.installTargets.x86_64-linux.extendModules { modules = [ hostName ]; }))
            "the machine image must point its three CA bundle paths at /run/plexsphere/ca-bundle.crt, seed that file from security.pki.caBundle through tmpfiles, and compose it in plexsphere-ca-trust.service after cloud-init.service and before cloud-config, cloud-final, k3s and plexd, ordering only; other nodes must keep the store bundle";

        # The image is 4G, and an instance gets the volume its flavor names.
        # Without the growth the node runs on the image's 3G of root whatever
        # the volume, until the container images k3s pulls fill it.
        # autoResize is only supported on ext2/3/4, so the file system type is
        # pinned with it.
        image-grows-root = passIf "image-grows-root"
          (lib.all
            (system:
              let image = imageSystems.${system}.config; in
              image.boot.growPartition
              && image.fileSystems."/".autoResize
              && image.fileSystems."/".fsType == "ext4")
            [ "x86_64-linux" "aarch64-linux" ])
          "the machine image must grow its root partition and its ext4 file system on boot";

        # nixpkgs' default initrd carries no virtio driver, and every OpenStack
        # cloud and every local QEMU hands the image a virtio disk and NIC. The
        # image that lacks them fails in stage 1 looking for its root device,
        # which no evaluation or build reports.
        image-boots-on-virtio = passIf "image-boots-on-virtio"
          (lib.all
            (system:
              let modules = imageSystems.${system}.config.boot.initrd.availableKernelModules; in
              lib.all (m: lib.elem m modules) [ "virtio_blk" "virtio_pci" "virtio_scsi" "virtio_net" ])
            [ "x86_64-linux" "aarch64-linux" ])
          "the machine image must carry the virtio block, PCI, SCSI and network drivers in its initrd";

        # x86 clouds boot SeaBIOS unless the image says otherwise, so the
        # x86_64 image boots from both firmwares, while aarch64 has UEFI only
        # and GRUB there has no i386-pc target. Neither may write EFI
        # variables, which an instance has no entry for and may not persist.
        # The serial console differs per architecture and is where the
        # platform's console log reads from.
        image-boot-loader-per-architecture =
          let
            x86_64 = imageSystems.x86_64-linux.config;
            aarch64 = imageSystems.aarch64-linux.config;
          in
          passIf "image-boot-loader-per-architecture"
            (x86_64.plexsphere.disk.biosBoot
              && x86_64.boot.loader.grub.enable
              && x86_64.boot.loader.grub.efiInstallAsRemovable
              && !x86_64.boot.loader.systemd-boot.enable
              && !aarch64.plexsphere.disk.biosBoot
              && aarch64.boot.loader.systemd-boot.enable
              && !aarch64.boot.loader.grub.enable
              && !x86_64.boot.loader.efi.canTouchEfiVariables
              && !aarch64.boot.loader.efi.canTouchEfiVariables
              && lib.elem "console=ttyS0,115200n8" x86_64.boot.kernelParams
              && lib.elem "console=ttyAMA0,115200n8" aarch64.boot.kernelParams)
            "the x86_64 image must boot with hybrid GRUB and the aarch64 image with systemd-boot, neither may touch EFI variables, and each must put a console on its architecture's serial port";

        # The output file name is what the README and the CI job name, and
        # disko derives it from imageName; the builder's derivation name
        # defaults to one derived from the empty host name. The device has to
        # stay a placeholder, because the builder substitutes /dev/vda for it
        # and a real path here would read as the disk the image goes onto.
        image-builder-settings = passIf "image-builder-settings"
          (lib.all
            (system:
              let
                image = imageSystems.${system}.config;
                disk = image.disko.devices.disk.main;
              in
              lib.hasPrefix "/dev/disk/by-id/REPLACE-ME" disk.device
              && disk.imageSize == "4G"
              && disk.imageName == "plexsphere-node-image-${system}"
              && image.disko.imageBuilder.name == "plexsphere-node-image-${system}"
              && image.disko.imageBuilder.imageFormat == "raw"
              && image.disko.memSize == 2048
              && lib.hasInfix "qemu-img convert" image.disko.imageBuilder.extraPostVM)
            [ "x86_64-linux" "aarch64-linux" ])
          "the machine image must keep its placeholder device, a 4G plexsphere-node-image-<system> raw build converted to qcow2, and a 2048 MiB builder VM";

        # The same coupling installer-target-state-version pins for the live
        # USB path: a node booted from the image is a fresh install and
        # declares the release of the nixpkgs it was built from, as a literal
        # rather than config.system.nixos.release, which would move on the
        # next bump.
        image-state-version = passIf "image-state-version"
          (imageSystems.x86_64-linux.config.system.stateVersion == lib.trivial.release)
          "the machine image's system.stateVersion must equal the release of the pinned nixpkgs; a node booted from it is a fresh install";

        # The README names what an operator types and where the files land:
        # the build commands, the output path image-builder-settings pins, the
        # plexd files and the CA directory the user-data writes, the unit
        # whose journal names the trusted certificates, the firmware property
        # and the NoCloud serial the boot commands depend on. Nothing but
        # agreement ties those strings to the module, and a drift shows only
        # on an instance that boots without its token, its identity or its
        # CA. The module side is pinned by the names the README explains it
        # with: the unit k3s and plexd wait for, the virtio profile, the
        # serial console and the composed bundle.
        # The README's first command after a boot is cloud-init status, which
        # resolves only because the image puts cloud-init on the PATH.
        image-docs-match-the-module =
          assert lib.all
            (system: lib.elem imageSystems.${system}.pkgs.cloud-init
              imageSystems.${system}.config.environment.systemPackages)
            [ "x86_64-linux" "aarch64-linux" ];
          pkgs.runCommand "image-docs-match-the-module" { } ''
            for pattern in \
                'nix build .#packages.x86_64-linux.image' \
                'result/plexsphere-node-image-x86_64-linux.qcow2' \
                '.#packages.aarch64-linux.image' \
                /etc/plexd/bootstrap-token \
                /etc/plexd/environment \
                PLEXD_PROJECT_ID= \
                PLEXD_RESOURCE_HANDLE= \
                PLEXD_API= \
                /etc/plexsphere/ca-certificates/ \
                plexsphere-ca-trust \
                hw_firmware_type=uefi \
                '-smbios type=1,serial=ds=nocloud' \
                cloud-localds \
                'cloud-init status --wait' \
                plexsphere.disk.biosBoot; do
              grep -q -F -- "$pattern" ${./README.md}
            done
            for pattern in cloud-final.service qemu-guest.nix ttyS0 /run/plexsphere/ca-bundle.crt; do
              grep -q -F -- "$pattern" ${./modules/image.nix}
            done
            touch $out
          '';

        # The upload runs only on a push to main, so no pull request executes
        # it, and a mistake in the script would first show after the merge, as
        # a failed publish or a broken download behind the fixed URL.
        # publish-test.sh runs the script against a stub sftp that behaves
        # like the server where it matters: uploaded files are read-only and
        # a rename does not replace. shellcheck runs first. The directory is
        # interpolated, not the two files, so the test finds publish.sh
        # beside itself in the store.
        publish-script-test =
          pkgs.runCommand "publish-script-test" { } ''
            ${pkgs.shellcheck}/bin/shellcheck \
              ${./.github/scripts}/publish.sh \
              ${./.github/scripts}/publish-test.sh
            bash ${./.github/scripts}/publish-test.sh
            touch $out
          '';

        # The publish steps are skipped on a pull request, so nothing there
        # runs the two lines naming the files to upload, and the README is
        # where an operator copies the download commands from. Nothing but
        # agreement ties image.filePath, where iso-image.nix puts the ISO
        # from the image.baseName modules/installer.nix sets and the
        # extension isoImage.compressImage decides, to the path the
        # installer job lists and uploads and to the URLs the README prints;
        # image-builder-settings pins the qcow2 name. The listing runs on
        # pull requests too, so a build that lands elsewhere fails there. A
        # renamed ISO or a mistyped path fails here, not as a failed publish
        # or a download that answers 404 after the merge. The README lines
        # are matched whole, because the curl line of a file is a prefix of
        # the curl line of its checksum and would keep passing with only the
        # latter left.
        published-files-match-the-docs =
          assert installerSystems.x86_64-linux.config.image.filePath
            == "iso/plexsphere-node-installer-x86_64-linux.iso";
          pkgs.runCommand "published-files-match-the-docs" { } ''
            grep -q -F -- 'du -h "$out/iso/plexsphere-node-installer-x86_64-linux.iso"' \
              ${./.github/workflows/check.yml}
            grep -q -F -- '.github/scripts/publish.sh "$ISO_DIR/iso/plexsphere-node-installer-x86_64-linux.iso"' \
              ${./.github/workflows/check.yml}
            grep -q -F -- '.github/scripts/publish.sh "$IMAGE_DIR/plexsphere-node-image-x86_64-linux.qcow2"' \
              ${./.github/workflows/check.yml}
            for name in \
                plexsphere-node-installer-x86_64-linux.iso \
                plexsphere-node-image-x86_64-linux.qcow2; do
              for line in \
                  "curl -fLO https://get.plexsphere.com/node/$name" \
                  "curl -fLO https://get.plexsphere.com/node/$name.sha256" \
                  "sha256sum -c $name.sha256"; do
                grep -q -x -F -- "$line" ${./README.md}
              done
            done
            touch $out
          '';
      };
    };
}
