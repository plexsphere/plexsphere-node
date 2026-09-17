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

        installer-iso = (installerSystem system).config.system.build.isoImage;
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

        # Applying the layout is destructive and irreversible, so the target
        # must be named per host rather than defaulted.
        disk-device-required = passIf "disk-device-required"
          (evalThrows (lib.nixosSystem {
            system = "x86_64-linux";
            modules = [ self.nixosModules.disk ];
          }).config.disko.devices.disk.main.device)
          "plexsphere.disk.device must have no default";

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

        # The check above covers the three mandatory fields; these are the two
        # the script writes only when the operator answered the prompt, and
        # neither is validated for it. An option renamed under
        # plexsphere.node throws — that is what the assert forces — but
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
                }
              ];
            };
          in
          assert installed.config.users.users.root.hashedPasswordFile
            == "/etc/plexsphere/root-password-hash";
          pkgs.runCommand "installer-injects-optional-identity" { } ''
            grep -q -F -- '.plexsphere.node.hashedPasswordFile = "/etc/plexsphere/root-password-hash"' \
              ${self.packages.x86_64-linux.plexsphere-install}/bin/plexsphere-install
            grep -q -F -- '.services.plexd.settings.api.base_url = $url' \
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
          (lib.all (system: (installerSystem system).config.system.build.isoImage ? drvPath)
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
                medium = (installerSystem system).config;
              in
              lib.elem script medium.environment.systemPackages
              && lib.hasInfix script.name medium.services.getty.helpLine)
            [ "x86_64-linux" "aarch64-linux" ])
          "the installer medium must ship plexsphere-install and name it on the console";

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
      };
    };
}
