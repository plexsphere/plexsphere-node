{ writeShellApplication
, coreutils
, util-linux
, openssh
, jq
, curl
, mkpasswd
, diskoInstall
, targetFlake
, targetAttr
}:

# The console half of the live installer. An install target deliberately
# carries no identity — plexsphere.node.hostName has no default and
# sshAuthorizedKeys stays empty — so everything a node needs to be reachable
# is collected here and handed to disko-install as a JSON module.
#
# disko-install builds installToplevel, closureInfo and diskoScript before it
# runs the partitioning script (disko-install:235-273), so a closure that
# cannot be built — no substituter reachable, an evaluation error — aborts
# with "Failed to build NixOS configuration" while the target disk is still
# untouched. That build is the last point at which nothing is lost.

writeShellApplication {
  name = "plexsphere-install";

  # systemctl comes from the ambient PATH (writeShellApplication appends
  # :$PATH), which on a NixOS live medium is where systemd lives; nixos-install,
  # xcp and nix come from disko-install's own wrapper. Naming any of them here
  # would pin a second copy of them into the closure of the ISO that ships this.
  runtimeInputs = [ diskoInstall coreutils util-linux openssh jq curl mkpasswd ];

  text = ''
    # nixpkgs' installation-device.nix auto-logs in the unprivileged "nixos"
    # user, so an unprivileged run is the expected first attempt, not an
    # unlikely one.
    if [ "$(id -u)" -ne 0 ]; then
      echo "plexsphere-install must run as root; use: sudo plexsphere-install" >&2
      exit 1
    fi

    # modules/disk.nix installs systemd-boot and touches EFI variables, and a
    # machine booted through the legacy BIOS path offers neither. Caught here
    # that costs a re-boot of the medium; caught by the bootloader step of
    # nixos-install it costs a disk that has already been repartitioned.
    if [ ! -d /sys/firmware/efi ]; then
      echo "this machine booted in legacy BIOS mode; the Plexsphere disk layout is UEFI-only. Re-boot the installer in UEFI mode." >&2
      exit 1
    fi

    # The node closure is fetched during the install, not carried on the
    # medium, so an unconfigured network has to be caught before the first
    # prompt rather than after the disk is partitioned. Three hosts and not
    # one: the flake this script installs from resolves its inputs against
    # this repository's committed flake.lock
    # (packages/install-target-flake.nix), where nixpkgs and disko are github
    # inputs whose source trees no part of the ISO carries, so the evaluation
    # disko-install runs here fetches both.
    #
    # github.com is not among the names it asks for. Both revisions are
    # pinned, so nix resolves no ref and the only request either input costs
    # is the tarball fetch, which nix's github fetcher addresses to
    # api.github.com and which answers with a redirect to codeload.github.com.
    # An egress allow-list naming cache.nixos.org and github.com — the pair a
    # probe of github.com would confirm — passes every check here and then
    # fails resolving api.github.com, with every prompt already answered. The
    # escape hatch is for an operator whose own infrastructure serves all
    # three.
    if [ "''${PLEXSPHERE_INSTALL_SKIP_NETWORK_CHECK:-}" != 1 ]; then
      for endpoint in https://cache.nixos.org/nix-cache-info https://api.github.com/ https://codeload.github.com/; do
        if ! curl --silent --show-error --fail --max-time 10 "$endpoint" > /dev/null; then
          echo "cannot reach $endpoint; the installer downloads the node closure from cache.nixos.org and fetches its flake inputs through api.github.com, which redirects to codeload.github.com. Configure networking with 'nmtui' and run plexsphere-install again." >&2
          exit 1
        fi
      done
    fi

    # Every secret this script writes lives here and nowhere else: /tmp is a
    # tmpfs on the live medium, so the plaintext hash and the token never
    # reach a disk, and the trap unlinks them whichever way the script leaves.
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    # The medium this is running from is a plain 'disk' to lsblk — a stick
    # written with dd is /dev/sda, type disk, indistinguishable from the
    # machine's own storage — and wiping it destroys the squashfs the running
    # installer reads its own binaries from, taking the target and the medium
    # with it. Stage 1 mounts the medium at /iso: off the whole device when
    # the image was written with dd, off a partition of it when it was not,
    # so ask for the mount points of a candidate and everything below it.
    carriesLiveMedium() {
      local mountPoint
      while read -r mountPoint; do
        [ "$mountPoint" != /iso ] || return 0
      done < <(lsblk --list --noheadings --output MOUNTPOINT "$1")
      return 1
    }

    # MODEL contains spaces, so the type is read off the last field rather
    # than the fourth, and the name off the first — a block device name
    # cannot contain a space, so the row carries both the candidate matched
    # against below and the line shown to the operator.
    candidates=()
    listing=()
    while read -r row; do
      [ "''${row##* }" = disk ] || continue
      carriesLiveMedium "''${row%% *}" && continue
      candidates+=("''${row%% *}")
      listing+=("$row")
    done < <(lsblk --nodeps --paths --noheadings --output NAME,SIZE,MODEL,TYPE)

    if [ "''${#candidates[@]}" -eq 0 ]; then
      echo "no disk to install onto: this machine has no block device of type 'disk' other than the live medium." >&2
      exit 1
    fi

    echo "Disks on this machine:"
    printf '  %s\n' "''${listing[@]}"

    while true; do
      printf 'Disk to install onto: '
      read -r answer
      device=
      for candidate in "''${candidates[@]}"; do
        if [ "$answer" = "$candidate" ]; then
          device=$candidate
          break
        fi
      done
      [ -z "$device" ] || break
      # --nodeps keeps partitions out of the list, and a partition is the
      # dangerous wrong answer: the layout would be applied to it in place,
      # repartitioning it and leaving a machine that does not boot.
      echo "$answer is not one of the disks listed above" >&2
    done

    # modules/disk.nix asks for a stable alias because a kernel name is
    # assigned in probe order and can name a different disk on the next boot
    # — which is the boot the installed node does. A wwn- alias is stable too
    # but says nothing about which disk it is, so it is the fallback rather
    # than the choice.
    #
    # The transport prefixes are named rather than everything-but-wwn taken,
    # because /dev/disk/by-id holds aliases udev derives from the contents of
    # the disk as well as from its hardware: a whole-device LVM physical
    # volume gets an lvm-pv-uuid- link, and md- and dm- links exist on the
    # same terms. Those name the data this install destroys. Taking one would
    # print the operator an identifier belonging to no physical disk at the
    # one prompt where the target is verified, and then hand disko a path that
    # udev removes the moment the destroy phase wipes the signature it was
    # derived from — leaving the create phase opening a path that no longer
    # resolves, with the partition table already gone. lvm-pv-uuid- also sorts
    # ahead of nvme-, scsi-, usb- and virtio-, so on those transports it is
    # what glob order offers first.
    byIdAlias() {
      local target=$1 link wwn=
      for link in /dev/disk/by-id/*; do
        [ -e "$link" ] || continue
        [ "$(readlink -f "$link")" = "$target" ] || continue
        case "''${link##*/}" in
          ata-* | nvme-* | scsi-* | usb-* | virtio-* | mmc-*)
            printf '%s\n' "$link"
            return 0
            ;;
          wwn-*) [ -n "$wwn" ] || wwn=$link ;;
        esac
      done
      [ -z "$wwn" ] || printf '%s\n' "$wwn"
    }

    # A kernel name is not a fallback here, it is a different disk waiting to
    # happen: the prompts below take minutes, and a re-enumeration in that
    # window — a stick unplugged, a controller reset — rebinds the name this
    # script would hand to disko-install and echo back at the confirmation.
    # The live medium was kept out of the list above by the kernel name it
    # held while that list was built, so the disk the chosen name lands on
    # afterwards can be the medium itself.
    byId=$(byIdAlias "$device")
    if [ -z "$byId" ]; then
      echo "$device has no /dev/disk/by-id alias, and a kernel name is assigned in probe order — it can name a different disk by the time this install starts, so it is not a target this installer will wipe. Give the disk a stable identifier, which for a virtual disk means a serial on its definition, and run plexsphere-install again." >&2
      exit 1
    fi
    device=$byId

    # Freezing the target is only half of it. byIdAlias resolved the kernel
    # name as it means now, not as it meant when the listing was built, so the
    # alias just frozen is whatever that name has come to point at — and the
    # exclusion that kept the medium out of the listing ran before the prompt,
    # against the old meaning. Re-check the path the wipe is aimed at, which
    # from here on names one disk and keeps naming it.
    if carriesLiveMedium "$device"; then
      echo "$device is the live medium this installer is running from: disk names were re-enumerated between the listing and your answer, so the name you typed no longer means the disk it was listed as. Run plexsphere-install again." >&2
      exit 1
    fi

    # k3s derives the Kubernetes node name from this, so it has to survive as
    # a DNS label.
    while true; do
      printf 'Host name: '
      read -r hostName
      if [[ $hostName =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        break
      fi
      echo "$hostName is not a valid host name; use 1 to 63 characters from a-z, 0-9 and '-', starting and ending with a letter or a digit" >&2
    done

    # Keys are fetched, never typed: a mistyped 68-character paste is the
    # single most likely way to end up with a node nobody can log into, and
    # password authentication is off on Plexsphere nodes.
    fetched=$(mktemp "$workdir/fetched.XXXXXX")
    keyFile=$(mktemp "$workdir/key.XXXXXX")
    while true; do
      printf 'Root SSH keys — GitHub username, or a full https:// URL: '
      read -r keySource

      case $keySource in
        https://*)
          keyUrl=$keySource
          ;;
        *)
          if [[ $keySource =~ ^[A-Za-z0-9]([A-Za-z0-9]|-[A-Za-z0-9]){0,38}$ ]]; then
            keyUrl="https://github.com/$keySource.keys"
          else
            # No request for an answer that cannot be either one.
            echo "not a GitHub username and not an https:// URL" >&2
            continue
          fi
          ;;
      esac

      # One path for every network shape, because curl says which it was: 22
      # for the 404 of an account that does not exist, 6 or 7 for a host that
      # does not resolve or does not answer, 28 for a timeout.
      #
      # The case above pins the first hop only, and curl's default protocol
      # set for a redirect includes plain HTTP and FTP — so a key server
      # answering 301 to http:// hands these keys, which become root's on a
      # k3s server, to whoever is on the path of a provisioning network. Pin
      # both hops instead. --max-filesize bounds the answer as --max-time
      # cannot: $fetched sits on the medium's tmpfs, which is RAM the closure
      # realisation needs, and 64 KiB holds more keys than a node has use for.
      if ! effectiveUrl=$(curl --silent --show-error --fail --location \
          --proto '=https' --proto-redir '=https' \
          --max-filesize 65536 --max-time 20 \
          --write-out '%{url_effective}' --output "$fetched" "$keyUrl"); then
        echo "could not fetch $keyUrl" >&2
        continue
      fi

      keys=()
      fingerprints=()
      lineNumber=0
      malformed=
      # read without IFS= strips the surrounding whitespace, so an indented
      # comment in a hosted authorized_keys file is still one; the trailing
      # test keeps a file whose last line has no newline from losing that key.
      while read -r line || [ -n "$line" ]; do
        lineNumber=$((lineNumber + 1))
        # The type test below is a prefix match; the keyPatterns of
        # plexsphere.node.sshAuthorizedKeys (modules/node.nix) match the whole
        # line, with exactly one space between the type and the blob. Two
        # shapes pass the first and fail the second, and ssh-keygen -l
        # fingerprints both without a word: a CRLF line ending, which read -r
        # leaves in $line because carriage return is not in IFS, and a run of
        # blanks between the fields. Both would be printed as authorized here
        # and rejected by the module assertion once disko-install builds the
        # closure. Reduce the line to the shape the option accepts instead —
        # ahead of the blank-line test, because under CRLF an empty separator
        # line is a lone carriage return and would otherwise be read as a key.
        line=''${line%$'\r'}
        IFS=' ' read -r keyType keyBlob keyComment <<< "$line"
        line=$keyType''${keyBlob:+ $keyBlob}''${keyComment:+ $keyComment}
        case $line in
          "" | "#"*) continue ;;
        esac
        # ssh-keygen -l is more permissive than the option that has to accept
        # these keys: it fingerprints an authorized_keys line carrying an
        # options prefix, a legacy ssh-dss key and an RSA key well below 2048
        # bits, and the keyPatterns of plexsphere.node.sshAuthorizedKeys
        # (modules/node.nix) reject all three. Left to ssh-keygen alone, such
        # a key is printed as authorized, confirmed, and then fails the
        # module assertion once disko-install builds the closure — with every
        # answer already given and the reason naming an option nobody set.
        case $line in
          "ssh-ed25519 "* | "ssh-rsa "* | "ecdsa-sha2-nistp256 "* | \
          "ecdsa-sha2-nistp384 "* | "ecdsa-sha2-nistp521 "* | \
          "sk-ssh-ed25519@openssh.com "* | "sk-ecdsa-sha2-nistp256@openssh.com "*) ;;
          *)
            echo "$keyUrl line $lineNumber is not one of the key types Plexsphere nodes accept; option prefixes (restrict, command=) and legacy types are rejected by plexsphere.node.sshAuthorizedKeys" >&2
            malformed=1
            break
            ;;
        esac
        printf '%s\n' "$line" > "$keyFile"
        # The comment is copied out of the fetched file verbatim and OpenSSH
        # does not sanitize it, so the control bytes that would rewrite what
        # the console shows are dropped before this reaches a terminal: the
        # printed fingerprint is the only thing authenticating these keys.
        # pipefail keeps ssh-keygen's own failure from being hidden by tr.
        if ! fingerprint=$(ssh-keygen -l -f "$keyFile" 2> /dev/null |
            tr -d '\000-\010\013-\037\177'); then
          # The whole response is rejected, not the offending line: a file
          # that is partly unreadable is a file whose contents nobody
          # vouched for, and installing the remainder would authorize a set
          # the operator never chose. The number is the line's number in the
          # fetched file, not its index among the lines that survived.
          echo "$keyUrl line $lineNumber is not an OpenSSH public key" >&2
          malformed=1
          break
        fi
        # ssh-keygen prints "<bits> <fingerprint> <comment> (<TYPE>)", and the
        # 2048-bit floor is the one node.nix pins through the RSA blob length.
        if [ "''${line%% *}" = ssh-rsa ] && [ "''${fingerprint%% *}" -lt 2048 ]; then
          echo "$keyUrl line $lineNumber is an RSA key below 2048 bits, which plexsphere.node.sshAuthorizedKeys rejects" >&2
          malformed=1
          break
        fi
        keys+=("$line")
        fingerprints+=("$fingerprint")
      done < "$fetched"

      [ -z "$malformed" ] || continue

      # GitHub answers 200 with an empty body for an account that has
      # published no keys, so the curl failure above does not cover this.
      if [ "''${#keys[@]}" -eq 0 ]; then
        echo "no SSH keys published at $keyUrl" >&2
        continue
      fi

      # The URL the bytes actually came off, which a redirect can make a
      # different one than the answer typed above.
      echo "Keys published at $effectiveUrl:"
      for fingerprint in "''${fingerprints[@]}"; do
        echo "  $fingerprint"
      done
      # Typed in full and no default: this prompt is the only place the keys
      # that will own root are authenticated, and a default-accept prompt is
      # one an operator gets past with the Enter they were already pressing.
      printf "Type 'yes' to authorize these keys for root on the node: "
      read -r answer
      [ "$answer" != yes ] || break
    done

    echo "Root password (optional). It authenticates at this machine's console"
    echo "only — SSH stays key-only — and buys a way in when the network or k3s"
    echo "is broken. Leave blank to leave root without a password."
    passwordHashFile=
    # IFS= on the reads below, unlike the ones over the key file above: read
    # strips the surrounding IFS whitespace, so a password carrying a leading
    # or trailing space — what pasting from a password manager over a serial
    # console produces — would be silently truncated before it reaches
    # mkpasswd. Both entries would be mangled identically, so the comparison
    # matches and nothing warns, and the hash would then cover a string other
    # than the one the operator recorded. This credential exists for the day
    # the network or k3s is broken and there is no second door: sshd keeps
    # PasswordAuthentication off (modules/node.nix).
    while true; do
      printf 'Root password: '
      IFS= read -rs password
      echo
      [ -n "$password" ] || break
      printf 'Repeat root password: '
      IFS= read -rs repeated
      echo
      if [ "$password" != "$repeated" ]; then
        echo "passwords do not match" >&2
        continue
      fi
      passwordHashFile=$workdir/root-password-hash
      # The plaintext is piped rather than passed as an argument, and the
      # hash is delivered as a file below instead of through
      # --system-config, which would write it into the world-readable Nix
      # store. plexsphere.node.hashedPasswordFile exists for that reason.
      (umask 077; printf '%s\n' "$password" | mkpasswd --method=yescrypt --stdin > "$passwordHashFile")
      break
    done

    # modules/plexd.nix resets /etc/plexd to 0750 root:root through a tmpfiles
    # rule on first boot, and disko-install copies extra files with cp -ar, so
    # the 0600 written here is the mode the token has on the node.
    #
    # Not echoed, for the same reason the password above is not: the token
    # registers a node with the control plane, and the console it would be
    # printed on is one this script cleans nothing up from. IFS= for the
    # reason given there too — a token silently shortened by a stray space is
    # a node that never registers.
    printf 'plexd bootstrap token (optional; leave blank to skip): '
    IFS= read -rs token
    echo
    tokenFile=
    if [ -n "$token" ]; then
      tokenFile=$workdir/bootstrap-token
      (umask 077; printf '%s\n' "$token" > "$tokenFile")
    fi

    # Blank keeps the mkDefault in modules/plexd.nix; an answer becomes a
    # plain definition in the injected module and wins over it — including
    # over the scheme. plexd presents the bootstrap token to this endpoint on
    # every start and every restart, so an http:// answer would put that
    # credential on the wire in cleartext and a scheme-less one would produce
    # a node that never reaches its control plane. services.plexd.settings is
    # freeform, so nothing downstream catches either.
    while true; do
      printf 'Control-plane URL (optional; blank keeps https://api.plexsphere.com): '
      read -r apiBaseUrl
      case $apiBaseUrl in
        "" | https://?*) break ;;
      esac
      echo "the control-plane URL must be a full https:// URL; plexd presents the bootstrap token to it" >&2
    done

    echo
    echo "About to install Plexsphere with:"
    echo "  disk:             $device"
    echo "  host name:        $hostName"
    echo "  root SSH keys:"
    for fingerprint in "''${fingerprints[@]}"; do
      echo "    $fingerprint"
    done
    if [ -n "$passwordHashFile" ]; then
      echo "  root password:    set, console only"
    else
      echo "  root password:    none"
    fi
    if [ -n "$tokenFile" ]; then
      echo "  bootstrap token:  supplied"
    else
      echo "  bootstrap token:  none"
    fi
    if [ -n "$apiBaseUrl" ]; then
      echo "  control plane:    $apiBaseUrl"
    else
      echo "  control plane:    https://api.plexsphere.com"
    fi
    echo
    echo "This rewrites the partition table of $device and destroys everything on it."
    printf "Type 'yes' to install, anything else to abort: "
    read -r answer
    if [ "$answer" != yes ]; then
      echo "aborted; nothing has been written to $device" >&2
      exit 1
    fi

    # jq builds the module, so quoting and escaping are its problem: a host
    # name or a key comment carrying a quote must not be able to break out of
    # the JSON that disko-install parses into a NixOS module.
    systemConfig=$(jq -n --arg hostName "$hostName" --arg device "$device" --args '
      {
        plexsphere: {
          node: { hostName: $hostName, sshAuthorizedKeys: $ARGS.positional },
          disk: { device: $device }
        }
      }' "''${keys[@]}")

    if [ -n "$passwordHashFile" ]; then
      systemConfig=$(jq '.plexsphere.node.hashedPasswordFile = "/etc/plexsphere/root-password-hash"' <<< "$systemConfig")
    fi

    if [ -n "$apiBaseUrl" ]; then
      systemConfig=$(jq --arg url "$apiBaseUrl" '.services.plexd.settings.api.base_url = $url' <<< "$systemConfig")
    fi

    # The flake reference and the disk name are spelled out rather than held
    # in variables: two flake checks grep this script for them, because
    # nothing else ties the strings in here to lib.installTargets and to the
    # disko disk declared in modules/disk.nix, and a rename on either side
    # would otherwise surface only once an operator runs the finished medium.
    args=(
      --flake ${targetFlake}#${targetAttr}
      --disk main "$device"
      --write-efi-boot-entries
      --system-config "$systemConfig"
    )

    if [ -n "$passwordHashFile" ]; then
      args+=(--extra-files "$passwordHashFile" /etc/plexsphere/root-password-hash)
    fi

    if [ -n "$tokenFile" ]; then
      args+=(--extra-files "$tokenFile" /etc/plexd/bootstrap-token)
    fi

    # errexit would take the exit status away before it can be reported.
    rc=0
    disko-install "''${args[@]}" || rc=$?

    if [ "$rc" -ne 0 ]; then
      # disko-install leaves the target's filesystems mounted when it fails
      # partway, and disko's destroy phase cannot wipe a busy device — so the
      # second run this message asks for would fail on the mounts of the
      # first. Recursive, and not fatal in itself: the status worth exiting
      # with is disko-install's, which is what the operator diagnoses over.
      # But an unmount that fails is precisely what breaks the retry below —
      # a descriptor still held under /mnt returns EBUSY here and leaves the
      # next run's wipefs against a busy device — so it has to be said rather
      # than routed to /dev/null. The mountpoint test keeps a failure that
      # mounted nothing in the first place — an unbuildable closure, which is
      # the likeliest of them — from reporting a problem it does not have.
      if mountpoint --quiet /mnt && ! umount --recursive /mnt; then
        echo "could not unmount /mnt; disko cannot wipe $device while it is busy, so a second plexsphere-install run will fail on it. Unmount it by hand or reboot the medium before retrying." >&2
      fi
      echo "installation failed; $device holds a partial install and will not boot. Fix the cause and run plexsphere-install again." >&2
      exit "$rc"
    fi

    echo
    echo "Plexsphere installed on $device."
    printf 'Reboot now? [Y/n] '
    read -r answer
    case ''${answer:-y} in
      [Yy] | [Yy][Ee][Ss]) systemctl reboot ;;
      *) echo "Not rebooting. Run 'systemctl reboot' when ready." ;;
    esac
  '';
}
