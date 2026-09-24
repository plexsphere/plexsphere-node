# plexsphere-node

A Nix flake that turns a machine into a Plexsphere node: from bare metal, from a running Linux over SSH, from a prebuilt disk image, or from an existing NixOS configuration. Every path ends in the same node:

- **k3s**, enabled as a single-node server
- **plexd** as a systemd service on the host (not a k3s workload), running the prebuilt release binary from [plexsphere/plexd](https://github.com/plexsphere/plexd); it connects the node to the Plexsphere control plane
- a declarative disk layout, network configuration and host identity (host name, root SSH keys)
- **x86_64** and **aarch64**

## Provisioning paths

| Path | Use it for |
|---|---|
| [Machine image](#machine-image) | VMs: local tests with KVM (QEMU or libvirt), OpenStack and other clouds. Ready-made qcow2, configured by cloud-init at first boot |
| [SSH takeover](#ssh-takeover) | Converting a machine that runs Linux and answers SSH, with nixos-anywhere |
| [Live USB installer](#live-usb-installer) | Installing onto local hardware with no usable operating system |
| [Existing NixOS machine](#existing-nixos-machine) | Adding the node profile to a NixOS configuration you already have |

The [node reference](#node-reference) covers the options, the firewall, the bootstrap token and upgrading plexd.

## Machine image

A qcow2 disk image of the node. It carries no identity of its own: every instance gets its host name, root's SSH keys, its network configuration and the plexd bootstrap token from cloud-init at first boot.

### Download

CI builds the x86_64 image on every push to `main` and publishes it to `https://get.plexsphere.com/node/`, replacing the previous one:

```bash
curl -fLO https://get.plexsphere.com/node/plexsphere-node-image-x86_64-linux.qcow2
curl -fLO https://get.plexsphere.com/node/plexsphere-node-image-x86_64-linux.qcow2.sha256
sha256sum -c plexsphere-node-image-x86_64-linux.qcow2.sha256
```

The checksum is served from the same host as the image, so it catches a broken download, not a tampered server. There is no published aarch64 image; build it yourself.

### Build it yourself

```bash
nix build .#packages.x86_64-linux.image
```

The image lands at `result/plexsphere-node-image-x86_64-linux.qcow2`. For aarch64 build `.#packages.aarch64-linux.image`. The build runs `nixos-install` in a QEMU VM, so it needs a Linux builder of the image's architecture with `/dev/kvm`; without it Nix refuses the build for the missing `kvm` system feature.

### What is in the image

- k3s and plexd, enabled. No host name, no root SSH key, no root password, no bootstrap token.
- A 4 GB disk. At first boot the root partition and its ext4 file system grow to fill the volume.
- The x86_64 image boots from BIOS and UEFI (GRUB in hybrid mode, `plexsphere.disk.biosBoot`). The aarch64 image boots from UEFI with systemd-boot.
- Kernel, systemd and a login prompt on the serial console: `ttyS0` on x86_64, `ttyAMA0` on aarch64.
- cloud-init writes the datasource's network configuration as systemd-networkd units. Without one, every Ethernet interface uses DHCP.
- k3s and plexd start after cloud-init has finished, so k3s registers under the host name from the user-data and plexd finds the token file.

### Write the user-data

```yaml
#cloud-config
hostname: plex-node-01
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... you@laptop
write_files:
  - path: /etc/plexd/bootstrap-token
    permissions: "0600"
    content: |
      <bootstrap token>
  - path: /etc/plexd/environment
    permissions: "0600"
    content: |
      PLEXD_PROJECT_ID=<project UUID>
      PLEXD_RESOURCE_HANDLE=<resource handle>
      PLEXD_API=https://cp.example.test
```

- **`hostname`** must match `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` and be unique across the cluster, because k3s derives the Kubernetes node name from it. OpenStack also sends the server name, and a NoCloud `meta-data` carries `local-hostname`. A node that gets no name at all comes up as `nixos`.
- **`ssh_authorized_keys`** go to `root`, the only account. Keys from the platform, such as an OpenStack keypair, are added too. The image has no root password, so an instance booted without any key cannot be logged into; boot a new one.
- **`/etc/plexd/bootstrap-token`** is where plexd reads the token (see [Bootstrap token](#bootstrap-token)).
- **`/etc/plexd/environment`** sets `PLEXD_PROJECT_ID`, the UUID of the project the node registers into, and `PLEXD_RESOURCE_HANDLE`, the platform resource it binds to. Without either, plexd exits with `project_id is required` or `resource_handle is required` and restarts every 5 seconds. `PLEXD_API` is optional and points plexd at a control plane other than `https://api.plexsphere.com`.

The user-data stays readable while the instance runs; on OpenStack the metadata service hands it, token included, to any process on the instance, pods included. The token is one-time, and plexd deletes the file after registering. To keep the token out of the user-data, drop its `write_files` entry and write the file after the boot:

```bash
ssh root@<address> 'umask 077; cat > /etc/plexd/bootstrap-token' <<< "$PLEXD_BOOTSTRAP_TOKEN"
```

### Boot it locally with KVM

For local tests, boot the image on a Linux machine with KVM, either with QEMU directly or through libvirt. Both hand cloud-init the user-data on a NoCloud seed image. Save the user-data above as `user-data`, and write `meta-data`:

```yaml
instance-id: plex-node-01
local-hostname: plex-node-01
```

Both ways need the DMI serial number `ds=nocloud`. Without it cloud-init does not look at the seed, probes network metadata services for about four minutes and then gives up: the node boots as `nixos` with no key and no token.

#### With QEMU

Needs a user that can open `/dev/kvm`. Build the seed, give the instance its own copy of the image, and boot it:

```bash
nix shell nixpkgs#cloud-utils -c cloud-localds seed.iso user-data meta-data
cp plexsphere-node-image-x86_64-linux.qcow2 plex-node-01.qcow2
nix shell nixpkgs#qemu -c qemu-img resize plex-node-01.qcow2 20G
nix shell nixpkgs#qemu -c qemu-system-x86_64 -accel kvm -cpu host -m 4G -smp 2 \
  -drive if=virtio,file=plex-node-01.qcow2 \
  -cdrom seed.iso \
  -smbios type=1,serial=ds=nocloud \
  -nic user,hostfwd=tcp::2222-:22 \
  -nographic
```

- The copy keeps the download untouched for the next instance. A self-built image has to be copied anyway, because the store path is read-only: `install -m 0644 result/plexsphere-node-image-x86_64-linux.qcow2 plex-node-01.qcow2`.
- `-smbios type=1,serial=ds=nocloud` sets the serial number.
- `-nographic` puts the serial console on your terminal. `Ctrl-a x` quits QEMU.
- `cloud-localds` and `qemu` from your distribution work as well as the `nix shell` ones.

Log in with `ssh -p 2222 root@localhost`. For a second instance use a new copy of the image, a seed with a different `instance-id` and `local-hostname`, and a different host port.

#### With libvirt

Needs libvirt with its `default` network, `virt-install` 4.0 or later, and a user in the `libvirt` group. virt-install builds the seed image from `user-data` and `meta-data` itself:

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
sudo install -m 0644 plexsphere-node-image-x86_64-linux.qcow2 /var/lib/libvirt/images/plex-node-01.qcow2
sudo qemu-img resize /var/lib/libvirt/images/plex-node-01.qcow2 20G
virt-install --name plex-node-01 --memory 4096 --vcpus 2 --cpu host-passthrough \
  --import --disk /var/lib/libvirt/images/plex-node-01.qcow2,bus=virtio \
  --osinfo linux2022 \
  --cloud-init user-data=user-data,meta-data=meta-data \
  --sysinfo system.serial=ds=nocloud \
  --network network=default \
  --graphics none --noautoconsole
```

- `--sysinfo system.serial=ds=nocloud` sets the serial number.
- virt-install treats the first boot as an installation and removes the seed afterwards. The node keeps what cloud-init wrote, but the first reboot from inside the guest shuts the domain off instead of restarting it. Start it again with `virsh start plex-node-01`; later reboots behave normally.

Find the address the node got from the `default` network, then log in:

```bash
virsh domifaddr plex-node-01
ssh root@<address>
```

`virsh console plex-node-01` attaches to the serial console, and `Ctrl-]` detaches. `virsh destroy plex-node-01 && virsh undefine plex-node-01 --remove-all-storage` removes the instance with its disk.

### Boot it on OpenStack

```bash
openstack image create --disk-format qcow2 --container-format bare \
  --file plexsphere-node-image-x86_64-linux.qcow2 plexsphere-node
openstack server create --image plexsphere-node --flavor <flavor> --network <network> \
  --key-name <keypair> --user-data user-data.yaml plex-node-01
```

The x86_64 image boots under the cloud's default firmware and with `--property hw_firmware_type=uefi` alike, so set that property only when the cloud requires it. For the aarch64 image add `--property hw_architecture=aarch64`. The flavor's disk must be at least 4 GB. `openstack console log show plex-node-01` shows the serial console.

### After the boot

```bash
ssh root@<address> cloud-init status --wait
ssh root@<address> systemctl is-active k3s plexd
ssh root@<address> k3s kubectl get node
```

`cloud-init status --wait` returns once cloud-init is done. A node booted from the image has no host flake to rebuild from: to change it, replace the instance with one booted from a new image.

## SSH takeover

Turns a machine that runs Linux and answers SSH into a node, driven from your own machine. [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) switches the target into a NixOS installer in RAM with kexec, partitions the disk, installs the node and reboots into it.

### Requirements

**The target** needs:

- x86_64 or aarch64 Linux with kexec support and at least 1.5 GB of RAM without swap. Containers and machines without kexec cannot be taken over; use the [live USB installer](#live-usb-installer).
- `tar`, `cpio` and a `setsid` that supports `--wait`.
- SSH login as `root`, or as a user with password-less `sudo`.
- **UEFI boot.** The layout installs systemd-boot, and nothing checks the firmware mode: a machine booted in BIOS mode ends up wiped and unbootable. Check first:

  ```bash
  ssh root@<address> 'test -d /sys/firmware/efi && echo UEFI || echo BIOS'
  ```

- Access to GitHub releases and `cache.nixos.org`.

**Your machine** needs Nix with the `nix-command` and `flakes` features, on Linux or macOS, and an SSH key the target accepts.

### Create the host flake

```bash
mkdir plex-node-01 && cd plex-node-01
nix flake init -t github:plexsphere/plexsphere-node#node
```

This writes `flake.nix` and `node.nix`. The flake defines `node-x86_64` and `node-aarch64`; use the one matching `uname -m` on the target. In a git repository, `git add` both files, because Nix only reads tracked files.

Edit `node.nix`:

1. **`plexsphere.node.hostName`**: unique across the cluster, matching `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`.
2. **`plexsphere.node.sshAuthorizedKeys`**: at least one root SSH key. Evaluation fails while it is empty or a key is malformed.
3. **`plexsphere.disk.device`**: the disk to wipe, as a `/dev/disk/by-id` alias. List them with `ssh root@<address> ls -l /dev/disk/by-id` and take one naming the hardware (`ata-`, `nvme-`, `scsi-`, `usb-`, `virtio-`, `mmc-`; `wwn-` only if there is no other). Not `/dev/sda`: the kexec boots a new kernel that may assign kernel names differently. Aliases such as `lvm-pv-uuid-`, `md-` or `dm-` vanish with the wipe. A virtual disk needs a serial in the hypervisor to get an alias.

The two commented lines are optional: a console root password (next step) and a control plane other than `https://api.plexsphere.com`. Leave `system.stateVersion` unchanged.

### Bootstrap token and root password

Both are optional and reach the node as files, never through the flake, whose files Nix copies into the world-readable store. Build a directory for `--extra-files` outside the flake directory:

```bash
extra=$(mktemp -d)
mkdir -p "$extra/etc/plexd" "$extra/etc/plexsphere"
(umask 077; printf '%s\n' "$PLEXD_BOOTSTRAP_TOKEN" > "$extra/etc/plexd/bootstrap-token")
(umask 077; nix run nixpkgs#mkpasswd -- --method=yescrypt > "$extra/etc/plexsphere/root-password-hash")
```

The last line prompts for the password. Keep it exactly when you uncomment `plexsphere.node.hashedPasswordFile` in `node.nix`. The password works on the console only; SSH stays key-only.

### Check, then run

Evaluate the node first. With `--build-on remote` the disk is partitioned before the node is built, so a mistake this command catches would otherwise show up on a wiped disk:

```bash
nix eval --raw .#nixosConfigurations.node-x86_64.config.system.build.toplevel.drvPath
```

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#node-x86_64 \
  --generate-hardware-config nixos-generate-config ./hardware-configuration.nix \
  --build-on remote \
  --extra-files "$extra" \
  --target-host root@<address>
```

- `--flake .#node-aarch64` for an ARM target.
- `--generate-hardware-config` writes `hardware-configuration.nix` next to `node.nix`, which the flake imports. Keep it: it carries the storage drivers, virtio included, and the CPU microcode.
- `--build-on remote` builds on the target. It is required on macOS; on a Linux machine of the target's architecture you can drop it.
- `--extra-files "$extra"`: drop it when you created no files.
- `--copy-host-keys` keeps the target's SSH host keys. Without it `ssh` warns about a changed host key until you run `ssh-keygen -R <address>`.

If the run fails after the kexec, the target keeps running the installer and still accepts your SSH key: fix `node.nix` and run the same command again. The disk may already be wiped by then. A disk alias that does not exist, such as the unedited `REPLACE-ME`, stops the run before anything is written.

### Afterwards

```bash
ssh root@<address> systemctl is-active k3s plexd
ssh root@<address> k3s kubectl get node
```

Keep the directory; `flake.nix`, `node.nix` and `hardware-configuration.nix` describe the node. Apply changes from a Linux machine with:

```bash
nixos-rebuild switch --flake .#node-x86_64 --target-host root@<address>
```

## Live USB installer

A bootable NixOS medium with `plexsphere-install`, which asks for the node's identity on the console and installs the node onto a local disk.

### Build and write the stick

```bash
nix build "git+file://$PWD?ref=HEAD#packages.x86_64-linux.installer-iso"
```

Building the committed `HEAD` keeps untracked files, such as a kubeconfig lying in the checkout, out of the medium's world-readable Nix store. For aarch64 build `packages.aarch64-linux.installer-iso` on an aarch64 builder.

`dd` overwrites the target device without asking. Name the stick, not one of your disks:

```bash
sudo dd if=result/iso/plexsphere-node-installer-x86_64-linux.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### Requirements

- **UEFI boot.** The installer refuses to run when the medium was booted in BIOS mode.
- **Network** with DHCP and access to `cache.nixos.org`, `api.github.com` and `codeload.github.com`: the node closure and the pinned flake inputs are downloaded during the install. The installer checks all three before the first question; `nmtui` is on the medium. `sudo PLEXSPHERE_INSTALL_SKIP_NETWORK_CHECK=1 plexsphere-install` skips that check, for networks that serve the three through their own infrastructure. It does not make an offline install possible.
- **At least 4.6 GiB of RAM.** The medium's writable Nix store is a tmpfs capped at half the RAM, and the node closure (1.8 GiB) is realised there before it is copied to the disk.

### Run the installer

The console logs in as `nixos`. Start the installer:

```bash
sudo plexsphere-install
```

It asks:

1. **Disk.** One of the whole disks it lists; the stick itself is not offered. The answer is resolved to a hardware `/dev/disk/by-id` alias, and a disk without one is refused. A virtual disk needs a serial in the hypervisor.
2. **Host name**, matching `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`.
3. **Root SSH keys**, as a GitHub username (`https://github.com/<user>.keys`) or an `https://` URL. The fingerprints are shown and confirmed with `yes`.
4. **Root password**, optional. Console only; SSH stays key-only.
5. **plexd bootstrap token**, optional (see [Bootstrap token](#bootstrap-token)).
6. **Control-plane URL**, optional; blank keeps `https://api.plexsphere.com`.

It then shows the answers and waits for `yes`. That is the point of no return: the target disk is wiped. Anything else aborts with the disk untouched. After the install the machine offers a reboot. The token lands in `/etc/plexd/bootstrap-token`, the password hash in `/etc/plexsphere/root-password-hash`, both `0600 root:root`.

## Existing NixOS machine

Add the flake input:

```nix
inputs.plexsphere-node.url = "github:plexsphere/plexsphere-node";
```

Import the node module into the host configuration:

```nix
{
  imports = [ plexsphere-node.nixosModules.node ];

  plexsphere.node.hostName = "plex-node-01";

  plexsphere.node.sshAuthorizedKeys = [
    "ssh-ed25519 AAAA... you@host"
  ];
}
```

`nixosModules.node` leaves the disk layout, `fileSystems` and the boot loader alone. `nixosModules.disk`, which the other paths add, carries the disko layout (GPT, ESP, ext4) with systemd-boot, or hybrid BIOS/UEFI GRUB with `plexsphere.disk.biosBoot`.

The profile passes `--secrets-encryption` to k3s. On a machine that already ran k3s, only Secrets written from then on are encrypted. Re-encrypt the existing ones once after the first rebuild:

```bash
k3s secrets-encrypt reencrypt --force
systemctl restart k3s
```

This protects a leaked datastore, not a stolen disk: the key lives in `/var/lib/rancher/k3s/server/cred/encryption-config.json` on the same unencrypted root file system. This repository does not configure full-disk encryption.

## Node reference

### Options

| Option | Type | Default | Description |
|---|---|---|---|
| `plexsphere.node.hostName` | str | required | Host name of the node. k3s derives the Kubernetes node name from it, so it must be unique across the cluster. |
| `plexsphere.node.sshAuthorizedKeys` | listOf str | `[ ]` | Root SSH keys in `ssh-keygen` form. Evaluation fails on an empty list (unless `services.cloud-init.enable` is set) and on a malformed or truncated key, because password authentication is off. RSA keys need at least 2048 bits. Option prefixes (`restrict`, `command=`) belong in `users.users.root.openssh.authorizedKeys.keys`. |
| `plexsphere.node.hashedPasswordFile` | nullOr str | `null` | Path to a file with a `mkpasswd` hash for root, read at activation and kept out of the Nix store. Console login only. |
| `plexsphere.disk.device` | str | required | Disk the disko layout is applied to (disk module). Applying the layout wipes it; use a `/dev/disk/by-id/…` path. |
| `plexsphere.disk.biosBoot` | bool | `false` | GRUB in hybrid BIOS/UEFI mode with a 1M BIOS boot partition, instead of UEFI-only systemd-boot (disk module, x86_64 only). The machine image sets it. |
| `services.plexd.enable` | bool | `false` | Run plexd. The node profile sets it to `true`. |
| `services.plexd.package` | package | plexd v0.8.0 release binary | The plexd package. |
| `services.plexd.settings` | YAML attrset | `{ api.base_url = "https://api.plexsphere.com"; }` | Rendered to `/etc/plexd/config.yaml`; host values override the preset. The file is in the world-readable Nix store, so no credentials. |

### Firewall

The NixOS firewall stays on. The node opens:

| Port | Interface | For |
|---|---|---|
| `51820/udp` (`services.plexd.settings.wireguard.listen_port`) | all | WireGuard handshakes from mesh peers |
| `32768-60999/tcp` | `plexd0` (`services.plexd.settings.wireguard.interface_name`) | remote sessions from the control plane |
| `6443/tcp`, `10250/tcp` | `cni0`, `flannel.1` | apiserver and kubelet, for pods |

- The session range is the kernel's ephemeral port range and is open to every mesh peer. Session forwards are unauthenticated, so the first peer to connect takes a session, and any other service listening on an ephemeral port on the mesh IP or on `0.0.0.0` is reachable by every peer. A host that changes `net.ipv4.ip_local_port_range` has to open its own range.
- The CNI interfaces are deliberately not trusted, which would expose sshd and everything else on `0.0.0.0` to every pod. Open further host ports for workloads explicitly.
- plexd's nftables table only enforces mesh policy on forwarded traffic; it is no host packet filter. Its health endpoints (`/healthz`, `/readyz`) listen on `127.0.0.1:9101` and are not opened. The bridge features (relay, user access, site-to-site) are off by default and need their own ports when enabled.

A single-node server needs nothing more. To join further nodes, open the cluster ports on the interface facing them:

```nix
networking.firewall.interfaces.eth0 = {
  allowedTCPPorts = [ 6443 10250 ];   # apiserver, kubelet metrics
  allowedUDPPorts = [ 8472 ];         # Flannel VXLAN
};
```

Flannel VXLAN is unauthenticated: whoever reaches `8472/udp` can inject frames into the pod network, past every NetworkPolicy. Never open it to an untrusted network.

### Bootstrap token

plexd reads its registration token from `/etc/plexd/bootstrap-token`, or from `PLEXD_BOOTSTRAP_TOKEN`, which `/etc/plexd/environment` can set. Write both files as `0600 root:root`; `/etc/plexd` is `0750`, but new files follow the current umask. This repository never puts the token into the configuration. Each path delivers it out of band:

- machine image: cloud-init `write_files` ([Write the user-data](#write-the-user-data))
- SSH takeover: `--extra-files` ([Bootstrap token and root password](#bootstrap-token-and-root-password))
- live USB installer: prompt
- existing NixOS machine: write the file yourself

### Upgrading plexd

Bump `version` in `packages/plexd.nix` and replace both SRI hashes with the values from the release's `checksums.sha256`:

```bash
nix hash convert --hash-algo sha256 --to sri <hex-digest>
```

The checksums come from the same release page as the binaries. CI additionally verifies each binary's sigstore bundle against plexd's release workflow:

```bash
cosign verify-blob \
  --certificate-identity-regexp '^https://github\.com/plexsphere/plexd/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-github-workflow-repository plexsphere/plexd \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --bundle plexd-linux-amd64.sigstore.json plexd-linux-amd64
```

The `plexd-package-has-session-helper` check runs the pinned binary's `plexd session-helper --help`, so a release without the subcommand the session helper unit starts fails `nix flake check`.
