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
      };
    };
}
