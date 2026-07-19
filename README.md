# plexsphere-node

NixOS-based provisioning toolkit for Plexsphere nodes. A Nix flake takes a machine from bare metal to a fully configured Plexsphere node in one step — modeled on [plexsphere/nixos-k3s](https://github.com/plexsphere/nixos-k3s).

> **Status:** early development — nothing is implemented yet. See the [open issues](https://github.com/plexsphere/plexsphere-node/issues) for the roadmap.

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

All three paths build on a **shared base configuration** ([#2](https://github.com/plexsphere/plexsphere-node/issues/2)) — a Nix flake describing the complete node target state. Applying it directly also converts an existing NixOS machine into a Plexsphere node.

## Why

Attaching a small baremetal machine to Plexsphere for testing is currently manual and unreproducible. This repository makes test nodes disposable and identical: point the flake at a reachable machine — or boot a stick or an image — and get a ready-to-enroll node every time.
