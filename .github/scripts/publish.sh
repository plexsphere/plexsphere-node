#!/usr/bin/env bash
#
# Publishes one file and its checksum to https://get.plexsphere.com/node/
# over SFTP.
#
#   usage: publish.sh <file>
#
# <file> goes up as /node/<basename>, next to /node/<basename>.sha256, a
# line that sha256sum -c checks after a download. The server and the
# credentials come from four environment variables, which CI fills from
# the repository secrets of the same names:
#
#   SFTP_HOST         host name of the SFTP server
#   SFTP_USER         the dedicated upload user
#   SFTP_PASSWORD     that user's password
#   SFTP_KNOWN_HOSTS  the server's host key lines, as ssh-keyscan prints them
#
# Exit status: 2 for a wrong argument count; 1 for a missing variable, a
# missing or empty file, or a failed command of the upload; 255 when the
# connection ends before the upload starts, as on a failed login or a host
# key mismatch.
set -euo pipefail

# The SFTP root is the web root, so this directory is what
# https://get.plexsphere.com/node/ serves. The upload creates it when it
# is missing.
remote_dir=/node

if [ "$#" -ne 1 ]; then
  echo 'usage: publish.sh <file>' >&2
  exit 2
fi
file=$1

# The :- makes an unset variable and an empty one the same case under
# set -u.
for secret in SFTP_HOST SFTP_USER SFTP_PASSWORD SFTP_KNOWN_HOSTS; do
  if [ -z "${!secret:-}" ]; then
    echo "::error::the repository secret $secret is not set"
    exit 1
  fi
done

if [ ! -f "$file" ]; then
  echo "::error::$file is not a file"
  exit 1
fi
# An empty upload would replace a working download.
if [ ! -s "$file" ]; then
  echo "::error::$file is empty"
  exit 1
fi

dir=$(cd "$(dirname -- "$file")" && pwd)
name=$(basename -- "$file")

# The template keeps the directory under TMPDIR on macOS as well, whose
# mktemp -d without one prefers the per-user temporary directory.
work=$(mktemp -d "${TMPDIR:-/tmp}/publish.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The password reaches ssh through this script, which prints it from the
# environment, so the password is never written to disk.
cat > "$work/sftp_askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$SFTP_PASSWORD"
EOF
chmod 700 "$work/sftp_askpass"

# The host key is checked against these lines and never trusted on first
# use, since a server that only claims to be the host would receive the
# password.
printf '%s\n' "$SFTP_KNOWN_HOSTS" > "$work/sftp_known_hosts"

# Computed inside the file's directory, so the line names the bare file
# name and sha256sum -c works next to a download.
(cd "$dir" && sha256sum "$name") > "$work/$name.sha256"

# sftp -b turns on BatchMode, which rules out password authentication.
# ssh keeps the first value it gets for an option, so -o BatchMode=no has
# to come before -b. SSH_ASKPASS_REQUIRE=force makes ssh use the askpass
# script without a terminal or a display. ConnectTimeout and the
# keepalives end the connection to a server that stops answering after a
# minute, rather than at GitHub's six-hour job limit with the publish
# group held all along.
#
# Both files go up under a hidden .part name and are renamed into place,
# so a download never reads a half-written file, and a failed upload
# leaves the published files as they were. A plain SFTP rename does not
# replace an existing file, so the old file is removed before each
# rename. That swap is not atomic: a failure during the last four
# commands, or a download between them, can find the file or its
# checksum missing, or the new file next to the old checksum, until the
# next publish succeeds. Leftover .part files of an aborted run are
# removed first: sftp carries the read-only mode of a Nix store file over
# to the uploaded file, and a read-only .part could not be written again.
#
# sftp -b aborts at the first failing command without a - prefix and
# exits 1. A failed login or a host key mismatch ends the connection
# before the batch, and sftp exits 255. sftp is the last command, so the
# script exits with its status. The - prefix marks the failures a normal
# run expects: -mkdir fails when /node exists, the first two -rm lines
# fail when no aborted run left a .part file behind, and the other two
# fail on the first publication of a file.
SSH_ASKPASS="$work/sftp_askpass" SSH_ASKPASS_REQUIRE=force \
sftp -o BatchMode=no -b - \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password,keyboard-interactive \
  -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
  -o "UserKnownHostsFile=$work/sftp_known_hosts" -o StrictHostKeyChecking=yes \
  "$SFTP_USER@$SFTP_HOST" <<EOF
-mkdir $remote_dir
-rm $remote_dir/.$name.part
-rm $remote_dir/.$name.sha256.part
put $dir/$name $remote_dir/.$name.part
put $work/$name.sha256 $remote_dir/.$name.sha256.part
-rm $remote_dir/$name
rename $remote_dir/.$name.part $remote_dir/$name
-rm $remote_dir/$name.sha256
rename $remote_dir/.$name.sha256.part $remote_dir/$name.sha256
EOF
