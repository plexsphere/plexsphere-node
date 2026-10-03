#!/usr/bin/env bash
#
# Tests publish.sh against a stub sftp, without a server and without Nix.
# The stub records how it was called and applies the batch to a local
# directory that stands in for the server's root. Like the real server, it
# makes every uploaded file read-only, so a put onto one fails, and does
# not rename onto an existing file, so a batch that drops one of its -rm
# lines fails here.
#
# Prints one "ok <scenario>" line per passing scenario. The first failed
# assertion prints "FAIL <scenario>: <reason>" to stderr and exits 1.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
publish=$here/publish.sh

password=not-a-real-password
known_hosts='files.example.invalid ssh-ed25519 AAAA'

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# The shebang is the bash on the PATH, because /usr/bin/env does not exist
# in the Nix build sandbox.
mkdir "$scratch/bin"
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'EOF'
set -eu
printf '%s\n' "$@" > "$STUB_STATE/args"
printf '%s\n' "${SSH_ASKPASS_REQUIRE:-}" > "$STUB_STATE/askpass_require"
"$SSH_ASKPASS" > "$STUB_STATE/password"
cp "$SSH_ASKPASS" "$STUB_STATE/askpass"
for arg in "$@"; do
  case $arg in
    UserKnownHostsFile=*) cp "${arg#UserKnownHostsFile=}" "$STUB_STATE/known_hosts" ;;
  esac
done

# ssh ends the connection on a failed login before sftp reads the batch.
if [ -n "${STUB_EXIT:-}" ]; then
  exit "$STUB_EXIT"
fi

apply() {
  case $1 in
    mkdir) mkdir "$STUB_ROOT$2" ;;
    rm) [ -e "$STUB_ROOT$2" ] && rm -f "$STUB_ROOT$2" ;;
    put) [ -z "${STUB_FAIL_PUT:-}" ] && [ ! -e "$STUB_ROOT$3" ] && cp "$2" "$STUB_ROOT$3" && chmod 0444 "$STUB_ROOT$3" ;;
    rename) [ ! -e "$STUB_ROOT$3" ] && mv "$STUB_ROOT$2" "$STUB_ROOT$3" ;;
    *) echo "sftp stub: unknown command $1" >&2; exit 1 ;;
  esac
}

while read -r command a b; do
  verb=${command#-}
  if ! apply "$verb" "$a" "$b" < /dev/null && [ "$verb" = "$command" ]; then
    echo "sftp stub: $command $a $b failed" >&2
    exit 1
  fi
done
EOF
} > "$scratch/bin/sftp"
chmod 755 "$scratch/bin/sftp"

output=
fail() {
  printf 'FAIL %s: %s\n' "$scenario" "$1" >&2
  if [ -n "$output" ]; then
    printf 'output of publish.sh:\n%s\n' "$output" >&2
  fi
  exit 1
}

# Starts a scenario with an empty stub root and no stub knobs set.
begin() {
  scenario=$1
  root=$scratch/$scenario/root
  mkdir -p "$root"
  output=
  unset_secret=
  empty_secret=
  stub_exit=
  fail_put=
}

# Runs publish.sh with the given arguments and records its combined output
# in output and its exit status in status. Every run gets a fresh, empty
# TMPDIR and a fresh directory for what the stub records.
runs=0
run_publish() {
  runs=$((runs + 1))
  state=$scratch/state-$runs
  tmp=$scratch/tmp-$runs
  mkdir "$state" "$tmp"
  status=0
  output=$(
    export PATH="$scratch/bin:$PATH" TMPDIR="$tmp" \
      STUB_STATE="$state" STUB_ROOT="$root" \
      SFTP_HOST=files.example.invalid SFTP_USER=uploader \
      SFTP_PASSWORD="$password" SFTP_KNOWN_HOSTS="$known_hosts"
    unset STUB_EXIT STUB_FAIL_PUT SSH_ASKPASS_REQUIRE
    if [ -n "$stub_exit" ]; then
      export STUB_EXIT="$stub_exit"
    fi
    if [ -n "$fail_put" ]; then
      export STUB_FAIL_PUT=1
    fi
    if [ -n "$unset_secret" ]; then
      unset "$unset_secret"
    fi
    if [ -n "$empty_secret" ]; then
      export "$empty_secret="
    fi
    bash "$publish" "$@" 2>&1
  ) || status=$?
}

# Writes $1 and a newline to a fresh artifact.iso and sets artifact to its
# path.
make_artifact() {
  mkdir "$scratch/$scenario/$1"
  artifact=$scratch/$scenario/$1/artifact.iso
  printf '%s\n' "$1" > "$artifact"
}

# Publishes artifact.iso with the content "first" into the stub root and
# sets first to its path.
seed_publication() {
  make_artifact first
  first=$artifact
  run_publish "$first"
  if [ "$status" -ne 0 ]; then
    fail "publishing the first artifact.iso exited $status"
  fi
}

expect_status() {
  if [ "$status" -ne "$1" ]; then
    fail "exit status $status, expected $1"
  fi
}

expect_output() {
  if [ "$output" != "$1" ]; then
    fail "output differs, expected: $1"
  fi
}

expect_stub_not_called() {
  if [ -e "$state/args" ]; then
    fail "sftp was called"
  fi
}

# Fails unless node/artifact.iso in the stub root equals $1, and the
# published checksum file is the line for the bare file name and verifies
# it.
expect_published() {
  if ! cmp -s "$1" "$root/node/artifact.iso"; then
    fail "node/artifact.iso differs from $1"
  fi
  if [ "$(cat "$root/node/artifact.iso.sha256")" \
      != "$(cd "$(dirname "$1")" && sha256sum artifact.iso)" ]; then
    fail "node/artifact.iso.sha256 is not the checksum line of artifact.iso"
  fi
  if ! (cd "$root/node" && sha256sum -c artifact.iso.sha256 > /dev/null 2>&1); then
    fail "sha256sum -c artifact.iso.sha256 fails in node/"
  fi
}

expect_no_part_files() {
  if [ -n "$(find "$root/node" -name '*.part')" ]; then
    fail "node/ holds .part files: $(find "$root/node" -name '*.part')"
  fi
}

expect_empty_tmpdir() {
  if [ -n "$(ls -A "$tmp")" ]; then
    fail "TMPDIR is not empty: $(ls -A "$tmp")"
  fi
}

# Prints the number of the first recorded sftp argument equal to $1, or
# nothing.
arg_line() {
  awk -v want="$1" '$0 == want { print NR; exit }' "$state/args"
}

pass() {
  printf 'ok %s\n' "$scenario"
}

begin publishes-file-and-checksum
make_artifact first
run_publish "$artifact"
expect_status 0
expect_published "$artifact"
expect_no_part_files
pass

begin replaces-read-only-publication
seed_publication
make_artifact second
run_publish "$artifact"
expect_status 0
expect_published "$artifact"
expect_no_part_files
pass

begin removes-leftover-part-files
mkdir "$root/node"
for part in .artifact.iso.part .artifact.iso.sha256.part; do
  printf 'aborted\n' > "$root/node/$part"
  chmod 0444 "$root/node/$part"
done
make_artifact first
run_publish "$artifact"
expect_status 0
expect_published "$artifact"
expect_no_part_files
pass

begin passes-sftp-options
make_artifact first
run_publish "$artifact"
expect_status 0
batch_mode=$(arg_line BatchMode=no)
batch_file=$(arg_line -b)
if [ -z "$batch_mode" ] || [ -z "$batch_file" ] \
    || [ "$batch_mode" -gt "$batch_file" ] \
    || [ "$(sed -n "$((batch_mode - 1))p" "$state/args")" != -o ]; then
  fail "-o BatchMode=no does not come before -b"
fi
for option in \
    PubkeyAuthentication=no \
    PreferredAuthentications=password,keyboard-interactive \
    StrictHostKeyChecking=yes \
    ConnectTimeout=30 \
    ServerAliveInterval=15 \
    ServerAliveCountMax=4; do
  if [ -z "$(arg_line "$option")" ]; then
    fail "the sftp arguments lack $option"
  fi
done
if [ "$(tail -n 1 "$state/args")" != uploader@files.example.invalid ]; then
  fail "the last sftp argument is not uploader@files.example.invalid"
fi
if [ "$(cat "$state/askpass_require")" != force ]; then
  fail "sftp runs without SSH_ASKPASS_REQUIRE=force"
fi
pass

begin keeps-password-out-of-askpass-file
make_artifact first
run_publish "$artifact"
expect_status 0
if [ "$(cat "$state/password")" != "$password" ]; then
  fail "the askpass script prints $(cat "$state/password")"
fi
if [ ! -f "$state/askpass" ] || grep -q -F -- "$password" "$state/askpass"; then
  fail "the askpass script contains the password"
fi
pass

begin writes-known-hosts-file
make_artifact first
run_publish "$artifact"
expect_status 0
if ! printf '%s\n' "$known_hosts" | cmp -s - "$state/known_hosts"; then
  fail "the known-hosts file is not SFTP_KNOWN_HOSTS and a newline"
fi
pass

begin leaves-no-temporary-files
make_artifact first
run_publish "$artifact"
expect_status 0
expect_empty_tmpdir
# The failing put comes after the work directory is created.
fail_put=1
make_artifact second
run_publish "$artifact"
expect_status 1
expect_empty_tmpdir
pass

begin empty-file-rejected
mkdir "$scratch/$scenario/empty"
artifact=$scratch/$scenario/empty/artifact.iso
: > "$artifact"
run_publish "$artifact"
expect_output "::error::$artifact is empty"
expect_status 1
expect_stub_not_called
pass

begin missing-file-rejected
artifact=$scratch/$scenario/missing/artifact.iso
run_publish "$artifact"
expect_output "::error::$artifact is not a file"
expect_status 1
expect_stub_not_called
pass

begin wrong-argument-count-rejected
make_artifact first
run_publish
expect_output 'usage: publish.sh <file>'
expect_status 2
expect_stub_not_called
run_publish "$artifact" "$artifact"
expect_output 'usage: publish.sh <file>'
expect_status 2
expect_stub_not_called
pass

begin unset-secret-rejected
make_artifact first
for unset_secret in SFTP_HOST SFTP_USER SFTP_PASSWORD SFTP_KNOWN_HOSTS; do
  run_publish "$artifact"
  expect_output "::error::the repository secret $unset_secret is not set"
  expect_status 1
  expect_stub_not_called
done
pass

begin empty-secret-rejected
make_artifact first
for empty_secret in SFTP_HOST SFTP_USER SFTP_PASSWORD SFTP_KNOWN_HOSTS; do
  run_publish "$artifact"
  expect_output "::error::the repository secret $empty_secret is not set"
  expect_status 1
  expect_stub_not_called
done
pass

begin failed-upload-keeps-publication
seed_publication
fail_put=1
make_artifact second
run_publish "$artifact"
expect_status 1
expect_published "$first"
pass

begin failed-login-keeps-publication
seed_publication
stub_exit=255
make_artifact second
run_publish "$artifact"
expect_status 255
expect_published "$first"
pass
