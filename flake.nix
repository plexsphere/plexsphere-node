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
        # the destructive script that would create them.
        example-hosts-evaluate = passIf "example-hosts-evaluate"
          (lib.all (system: (exampleHost system).config.system.build.toplevel ? drvPath)
            [ "x86_64-linux" "aarch64-linux" ])
          "the example host modules must evaluate on both architectures";
      };
    };
}
