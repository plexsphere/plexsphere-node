# plexsphere-node

NixOS-based provisioning toolkit for Plexsphere nodes. A Nix flake takes a machine from bare metal to a fully configured Plexsphere node in one step — modeled on [plexsphere/nixos-k3s](https://github.com/plexsphere/nixos-k3s).

> **Status:** the shared base configuration ([#2](https://github.com/plexsphere/plexsphere-node/issues/2)) and the live USB installer ([#4](https://github.com/plexsphere/plexsphere-node/issues/4)) are implemented; the two remaining provisioning paths — SSH takeover ([#3](https://github.com/plexsphere/plexsphere-node/issues/3)) and machine image ([#5](https://github.com/plexsphere/plexsphere-node/issues/5)) — are upcoming. See the [open issues](https://github.com/plexsphere/plexsphere-node/issues) for the roadmap.

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

## Install from a live USB stick

The live installer is a bootable NixOS medium carrying `plexsphere-install`, an interactive script that collects a node's identity on the console and installs a complete Plexsphere node onto a local disk. Use it on hardware with no usable operating system.

### Build the image

```bash
nix build .#packages.x86_64-linux.installer-iso
```

The image lands at `result/iso/plexsphere-node-installer-x86_64-linux.iso`. For an aarch64 machine build `.#packages.aarch64-linux.installer-iso`, which needs an aarch64 builder — an image is mastered on the architecture it boots.

Build from a clean checkout. The medium carries this flake's own source as a store path, and for a dirty working tree Nix copies every file the checkout holds that `.gitignore` does not exclude — untracked ones included. A `kubeconfig`, a token dump or an `.envrc` left lying in the directory is therefore written into the world-readable Nix store of the image, onto every stick burnt from it and into the store of every node installed from those. That an image built this way also installs nodes from uncommitted sources is the smaller half of it. Check `git status` before you build, or build the committed `HEAD` and leave the working tree out of it:

```bash
nix build "git+file://$PWD?ref=HEAD#packages.x86_64-linux.installer-iso"
```

### Write the stick

`dd` overwrites the target device completely and asks nothing. Name the stick, never one of the machine's disks:

```bash
sudo dd if=result/iso/plexsphere-node-installer-x86_64-linux.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

`oflag=sync` keeps `dd` from returning while the write is still in the page cache, so the stick is safe to unplug once the command exits.

### What the target machine needs

**UEFI.** Boot the medium in UEFI mode. The installer refuses to run on a machine booted in legacy BIOS mode, because the Plexsphere disk layout installs systemd-boot onto an ESP and a BIOS boot offers neither EFI variables nor firmware that reads them. The same medium boots both ways, so this costs a firmware setting and a re-boot — the same mismatch caught later, at the bootloader step, costs a disk that has already been repartitioned.

**A network.** The image is generic and carries no node closure: the installer downloads it during the install. The machine needs DHCP and a route to three hosts — `cache.nixos.org`, which serves the node closure, and `api.github.com` with `codeload.github.com`, which between them serve the flake inputs the install target evaluates against (`nixpkgs` and `disko`, at the revisions this repository's `flake.lock` pins; the medium carries neither source tree). Those two and not `github.com`: both revisions are pinned, so Nix resolves no ref and asks only for the tarball of each input, which its `github` fetcher addresses to `api.github.com` and which answers with a redirect to `codeload.github.com`. The installer probes all three before the first prompt rather than after the disk is gone. `nmtui` is on the medium for anything DHCP does not solve. `PLEXSPHERE_INSTALL_SKIP_NETWORK_CHECK=1` skips that pre-flight reachability probe and nothing else — it is for an operator whose own infrastructure serves all three. It does not make the install work offline. `sudo` resets the environment, so set it on the `sudo` command line rather than in front of it:

```bash
sudo PLEXSPHERE_INSTALL_SKIP_NETWORK_CHECK=1 plexsphere-install
```

**At least 4.6 GiB of RAM.** The live medium keeps the writable half of its Nix store on `/nix/.rw-store`, which nixpkgs' `iso-image.nix` mounts as a tmpfs with no `size=` option — so the kernel default applies and that store can grow to half the machine's RAM and no further. `disko-install` realises the whole node closure there before copying it to the target disk, and the node closure measures **1.8 GiB** (`nix path-info -Sh` over an installed system, at the nixpkgs pinned in `flake.lock`). Fitting 1.8 GiB into a tmpfs that stops at half of RAM takes 3.6 GiB, plus about 1 GiB for the running system: **4.6 GiB**. Redo that arithmetic when the closure grows.

### Run the installer

The medium logs a console in automatically as the unprivileged `nixos` user, and its help line names the command:

```bash
sudo plexsphere-install
```

It asks six questions, in this order:

1. **Disk to install onto.** One of the disks it lists. The list holds whole disks only, and a partition is rejected: applying the layout to a partition would repartition it in place and leave a machine that does not boot. The stick the installer is running from is left out of the list — to `lsblk` it is a disk like any other, and wiping it would destroy the running installer along with the target. Your answer is resolved to a stable `/dev/disk/by-id` alias, and a disk that has none is refused: a kernel name such as `/dev/sda` is assigned in probe order, so it can come to mean a different disk between this prompt and the partition table being rewritten five prompts later — and the next boot after that is the installed node's. Only aliases naming the hardware count — `ata-`, `nvme-`, `scsi-`, `usb-`, `virtio-`, `mmc-`, and `wwn-` as a last resort. The ones udev derives from what is written on the disk, such as the `lvm-pv-uuid-…` link a whole-disk physical volume gets, are not identifiers of a disk and do not survive the wipe they would be pointed at. A virtual disk typically has no alias until its definition carries a serial, so give it one in the hypervisor and run the installer again. The resolved alias is then checked against the live medium a second time, because the exclusion behind the list ran against the kernel names the disks held while the list was printed: if a re-enumeration while you were reading it made the name you typed mean the stick, the installer stops instead of wiping itself.
2. **Host name.** Must match `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`. k3s derives the Kubernetes node name from it, so it has to survive as a DNS label.
3. **Root SSH keys.** A GitHub username, expanded to `https://github.com/<user>.keys`, or a full `https://` URL. The fetch stays on HTTPS across redirects, so a key server answering with a plain-HTTP `Location` is refused rather than followed. The keys are fetched, their fingerprints printed, and you authorize them by typing `yes` — a key is never typed or pasted at this prompt, because a mistyped 68-character paste is the likeliest way to end up with a node nobody can log into. Every line of the fetched file must parse as an OpenSSH public key of a type `plexsphere.node.sshAuthorizedKeys` accepts; one bad line rejects the whole response, since a file that is partly unreadable is a file nobody vouched for.
4. **Root password.** Optional, entered twice and never echoed. It is a console credential only — SSH stays key-only, so it cannot log in over the network — and it buys a way in when the network or k3s is broken. Blank leaves root without a password.
5. **plexd bootstrap token.** Optional; blank skips it, and it is not echoed — it is a node-registration credential. See [Bootstrap token](#bootstrap-token) for what it is.
6. **Control-plane URL.** Optional; blank keeps `https://api.plexsphere.com`. An answer must be a full `https://` URL: plexd presents the bootstrap token to this endpoint on every start.

The installer then prints back everything it collected and asks you to type `yes`. That is the point of no return: the next thing that happens rewrites the partition table of the target disk and destroys everything on it. Anything other than `yes` aborts with the disk untouched. When the install succeeds, the machine offers a reboot.

Two of your answers become files on the installed node, both `0600 root:root` and both outside the Nix store, which is world-readable: the bootstrap token at `/etc/plexd/bootstrap-token`, and the root password hash at `/etc/plexsphere/root-password-hash`.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `plexsphere.node.hostName` | str | none — required | Network host name of the node. k3s derives the Kubernetes node name from it, so it must be unique across the cluster. |
| `plexsphere.node.sshAuthorizedKeys` | listOf str | `[ ]` | Root SSH keys in `ssh-keygen` form. Evaluation fails on an empty list or a malformed entry: password authentication is disabled and sshd skips a malformed key silently, so either mistake leaves the node unreachable. The key type and the blob length are both checked, so a truncated paste is caught as well; RSA below 2048 bits is rejected. Option prefixes (`restrict`, `command=`) are not accepted here — set those via `users.users.root.openssh.authorizedKeys.keys`. |
| `plexsphere.node.hashedPasswordFile` | nullOr str | `null` | Path to a file holding the root password as a single `mkpasswd` hash, on one line. nixpkgs reads it on every system activation, so this is a plain filesystem path and never a store path — the hash stays out of the world-readable Nix store. The credential authenticates at the machine's console only, because the profile keeps `PasswordAuthentication = false`; it is no substitute for an SSH key, which stays mandatory. |
| `plexsphere.disk.device` | str | none — required | Disk the disko layout is applied to (disk module only). Applying the layout destroys all data on it, so name it per host — preferably as a stable `/dev/disk/by-id/…` path, since `/dev/sdX` is assigned in probe order. |
| `services.plexd.enable` | bool | `false` | Whether to run plexd (the node profile sets it to `true`). |
| `services.plexd.package` | package | plexd v0.2.0 release binary | The plexd package to run. |
| `services.plexd.settings` | YAML attrset | `{ api.base_url = "https://api.plexsphere.com"; }` | Freeform settings rendered to `/etc/plexd/config.yaml`; the preset `api.base_url` is a default, so any host-level value wins. The rendered file lands in the world-readable Nix store, so it must not carry credentials. |

## Bootstrap token

plexd reads its registration bootstrap token from `/etc/plexd/bootstrap-token` (plexd's `registration.token_file` default) or from the `PLEXD_BOOTSTRAP_TOKEN` environment variable, which can be set via `/etc/plexd/environment` (picked up by the unit's optional `EnvironmentFile`).

Both files are node-registration credentials: write them as mode `0600`, owned by `root`. The module keeps `/etc/plexd` itself at `0750 root:root`, but the files an operator drops there inherit the current umask.

This repository deliberately does not manage the token — delivery is out of band. On an existing machine the operator writes it directly; the live USB installer ([#4](https://github.com/plexsphere/plexsphere-node/issues/4)) prompts for it and writes it to `/etc/plexd/bootstrap-token` at `0600`, and the two remaining provisioning paths ([#3](https://github.com/plexsphere/plexsphere-node/issues/3)/[#5](https://github.com/plexsphere/plexsphere-node/issues/5)) deliver it their own way (cloud-init delivery is [#5](https://github.com/plexsphere/plexsphere-node/issues/5)'s scope).

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
