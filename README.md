# plexsphere-node

NixOS-based provisioning toolkit for Plexsphere nodes. A Nix flake takes a machine from bare metal to a fully configured Plexsphere node in one step — modeled on [plexsphere/nixos-k3s](https://github.com/plexsphere/nixos-k3s).

> **Status:** the shared base configuration ([#2](https://github.com/plexsphere/plexsphere-node/issues/2)) is implemented; the three provisioning paths — SSH takeover ([#3](https://github.com/plexsphere/plexsphere-node/issues/3)), live USB installer ([#4](https://github.com/plexsphere/plexsphere-node/issues/4)), and machine image ([#5](https://github.com/plexsphere/plexsphere-node/issues/5)) — are upcoming. See the [open issues](https://github.com/plexsphere/plexsphere-node/issues) for the roadmap.

## What a finished node looks like

Every provisioning path converges on the same target state:

- **k3s** enabled by default
- **plexd** running as a systemd service directly on the host (not as a k3s workload), consumed as the prebuilt Go binary released from [plexsphere/plexd](https://github.com/plexsphere/plexd) — it connects the node to the Plexsphere control plane
- Declarative disk layout, initial network configuration, and host identity (hostname, SSH keys)
- Supported architectures: **x86_64** and **aarch64**

## Provisioning paths

| Path | Use case | Issue |
|---|---|---|
| **SSH takeover** | Convert an existing SSH-reachable Linux machine in place, in the style of nixos-anywhere | [#3](https://github.com/plexsphere/plexsphere-node/issues/3) |
| **Live USB installer** | Install onto local hardware with no usable operating system | [#4](https://github.com/plexsphere/plexsphere-node/issues/4) |
| **Machine image** | Prebuilt bootable disk image for virtualized and cloud platforms (e.g. OpenStack), with cloud-init first-boot configuration | [#5](https://github.com/plexsphere/plexsphere-node/issues/5) |

All three paths build on a **shared base configuration** ([#2](https://github.com/plexsphere/plexsphere-node/issues/2)) that lives in this repository: a Nix flake exporting `nixosModules.node` and `nixosModules.disk`, which describe the complete node target state. Applying `nixosModules.node` directly converts an existing NixOS machine into a Plexsphere node.

## Use on an existing NixOS machine

Add this repository as a flake input:

```nix
inputs.plexsphere-node.url = "github:plexsphere/plexsphere-node";
```

Import `plexsphere-node.nixosModules.node` into the host configuration, name the node, and authorize at least one root SSH key:

```nix
{
  imports = [ plexsphere-node.nixosModules.node ];

  plexsphere.node.hostName = "plex-node-01";

  plexsphere.node.sshAuthorizedKeys = [
    "ssh-ed25519 AAAA... you@host"
  ];
}
```

The node profile enables k3s (single-node `server` role) and plexd by default.

The NixOS firewall stays on. plexd's nftables table hooks `forward`: it enforces mesh peer policy on packets routed between peers and never filters traffic addressed to the host, so it is not a host packet filter and does not compete with one. Enabling plexd opens its WireGuard port (`services.plexd.settings.wireguard.listen_port`, default `51820/udp`) so peers can hand shake in; plexd's bridge features (relay, user access, site-to-site) are off by default and need their own ports opened when enabled. On the CNI devices (`cni0`, `flannel.1`) the profile opens the two ports pods need on the host: `6443` (apiserver) and `10250` (kubelet). It deliberately does not mark those devices trusted — a trusted interface accepts every port, which would expose sshd and anything else bound to `0.0.0.0` to every pod on the node. A workload that needs another host port needs it added here.

Nothing else is opened — a single-node server needs none of it. Joining further nodes means opening the cluster ports deliberately, on the interface facing the other nodes:

```nix
networking.firewall.interfaces.eth0 = {
  allowedTCPPorts = [ 6443 10250 ];   # apiserver, kubelet metrics
  allowedUDPPorts = [ 8472 ];         # Flannel VXLAN
};
```

Flannel VXLAN is unauthenticated: anything that can send to `8472/udp` can inject frames onto the pod overlay, past every NetworkPolicy. Never open it to an untrusted network.

Importing only `nixosModules.node` never touches the machine's disk layout, `fileSystems`, or boot loader — from-scratch installs (the provisioning paths) additionally compose `nixosModules.disk`, which carries the disko GPT/ESP/ext4 layout and systemd-boot.

### Secrets encryption on an already-running server

The profile passes `--secrets-encryption` to k3s servers. On a machine that was already running k3s, that flag encrypts **newly written** Secrets only — everything already in the datastore stays in plain text until it is rewritten. After the first rebuild, re-encrypt once:

```bash
k3s secrets-encrypt reencrypt --force
systemctl restart k3s
```

The flag bounds a leak of the datastore alone, such as a copied database file or a backup that excludes the credential directory. It is not protection against offline access to the disk: k3s stores the AES key in `/var/lib/rancher/k3s/server/cred/encryption-config.json` on the same unencrypted root filesystem, so a stolen or snapshotted drive yields the ciphertext and the key together. Full-disk encryption is the control for that threat and this repository does not configure it.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `plexsphere.node.hostName` | str | none — required | Network host name of the node. k3s derives the Kubernetes node name from it, so it must be unique across the cluster. |
| `plexsphere.node.sshAuthorizedKeys` | listOf str | `[ ]` | Root SSH keys in `ssh-keygen` form. Evaluation fails on an empty list or a malformed entry: password authentication is disabled and sshd skips a malformed key silently, so either mistake leaves the node unreachable. The key type and the blob length are both checked, so a truncated paste is caught as well; RSA below 2048 bits is rejected. Option prefixes (`restrict`, `command=`) are not accepted here — set those via `users.users.root.openssh.authorizedKeys.keys`. |
| `plexsphere.disk.device` | str | none — required | Disk the disko layout is applied to (disk module only). Applying the layout destroys all data on it, so name it per host — preferably as a stable `/dev/disk/by-id/…` path, since `/dev/sdX` is assigned in probe order. |
| `services.plexd.enable` | bool | `false` | Whether to run plexd (the node profile sets it to `true`). |
| `services.plexd.package` | package | plexd v0.2.0 release binary | The plexd package to run. |
| `services.plexd.settings` | YAML attrset | `{ api.base_url = "https://api.plexsphere.com"; }` | Freeform settings rendered to `/etc/plexd/config.yaml`; the preset `api.base_url` is a default, so any host-level value wins. The rendered file lands in the world-readable Nix store, so it must not carry credentials. |

## Bootstrap token

plexd reads its registration bootstrap token from `/etc/plexd/bootstrap-token` (plexd's `registration.token_file` default) or from the `PLEXD_BOOTSTRAP_TOKEN` environment variable, which can be set via `/etc/plexd/environment` (picked up by the unit's optional `EnvironmentFile`).

Both files are node-registration credentials: write them as mode `0600`, owned by `root`. The module keeps `/etc/plexd` itself at `0750 root:root`, but the files an operator drops there inherit the current umask.

This repository deliberately does not manage the token — delivery is out of band. On an existing machine the operator writes it directly, and the provisioning paths ([#3](https://github.com/plexsphere/plexsphere-node/issues/3)/[#4](https://github.com/plexsphere/plexsphere-node/issues/4)/[#5](https://github.com/plexsphere/plexsphere-node/issues/5)) deliver it their own way (cloud-init delivery is [#5](https://github.com/plexsphere/plexsphere-node/issues/5)'s scope).

## Upgrading plexd

Bump `version` in `packages/plexd.nix` and replace both SRI hashes with values converted from the new release's `checksums.sha256`:

```bash
nix hash convert --hash-algo sha256 --to sri <hex-digest>
```

`checksums.sha256` is published on the same release page as the binaries, so it only proves the two agree with each other. CI additionally verifies the sigstore bundle shipped with each asset, which is what ties the bytes to the plexd release pipeline:

```bash
cosign verify-blob \
  --certificate-identity-regexp '^https://github\.com/plexsphere/plexd/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-github-workflow-repository plexsphere/plexd \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --bundle plexd-linux-amd64.sigstore.json plexd-linux-amd64
```

The identity is pinned down to the release workflow and the tag refs it runs on. Anchoring on the repository alone would accept a signature from any workflow on any branch or pull-request ref of `plexsphere/plexd`, which proves only that the bytes passed through that repository — not that they came from its release pipeline.

## Why

Attaching a small baremetal machine to Plexsphere for testing is currently manual and unreproducible. This repository makes test nodes disposable and identical: point the flake at a reachable machine — or boot a stick or an image — and get a ready-to-enroll node every time.
