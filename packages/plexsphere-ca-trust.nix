{ writeShellApplication
, coreutils
, gnugrep
, openssl
}:

# Composes the machine image's CA bundle at boot. The image is one disk for
# every instance booted from it, so no private CA can be built into the
# bundle in its store; the user-data writes the certificates an instance
# trusts to a directory instead, and this appends them to a copy of the
# system bundle.
#
# Every file is held to the rule the live installer applies to its answer
# (packages/plexsphere-install.nix): exactly one PEM block, which openssl has
# to parse as a certificate, and only openssl's encoding of that certificate
# is appended. A key in a file therefore never reaches the bundle, which
# every user on the node can read, and a file holding several certificates
# is skipped instead of trusting more than the one whose fingerprint was
# compared.
#
# The optional fourth argument is the bundle file the plexsphere broker's
# cloud-init document writes, and it may hold several certificates. The
# one-certificate rule exists so nothing is trusted beyond the certificate
# whose fingerprint an operator compared. The bundle file holds the control
# plane's configured bundle, which the broker validated block by block, and
# it arrives in the same user-data that already sets root's keys and runs
# commands as root. It is still trusted whole or not at all: every PEM block
# in it has to be a certificate openssl parses, or none of them is
# appended, and only openssl's encoding of each one is. A missing bundle
# file, or one holding nothing but whitespace, is a document without a
# bundle and adds nothing.

writeShellApplication {
  name = "plexsphere-ca-trust";

  runtimeInputs = [ coreutils gnugrep openssl ];

  text = ''
    if [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; then
      echo "usage: plexsphere-ca-trust <system bundle> <certificate directory> <output bundle> [<bundle file>]" >&2
      exit 2
    fi
    systemBundle=$1
    certificateDirectory=$2
    output=$3
    bundleFile=''${4-}

    # Composed beside the output and renamed over it, so no reader sees a
    # partial bundle. The bundle file is cut into pieces, one per PEM block,
    # in a directory beside the output as well. The trap removes both
    # whichever way the script leaves, so the directory is made on every
    # run: the trap names it, and nounset would fail the trap on a run that
    # never made it.
    composed=$(mktemp "$output.XXXXXX")
    pieces=$(mktemp -d "$output.XXXXXX")
    trap 'rm -rf "$composed" "$pieces"' EXIT

    if ! cat "$systemBundle" > "$composed"; then
      echo "cannot read the system bundle $systemBundle; $output is left as it was" >&2
      exit 1
    fi

    # The subject comes out of the certificate, and -nameopt RFC2253 escapes
    # its control bytes and every byte above 0x7f, as the installer does
    # with the subject it shows.
    describe() {
      printf '%s %s' \
        "$(openssl x509 -in "$1" -noout -subject -nameopt RFC2253)" \
        "$(openssl x509 -in "$1" -noout -fingerprint -sha256)"
    }

    # A missing or empty directory adds nothing.
    shopt -s nullglob
    skipped=
    for file in "$certificateDirectory"/*.crt; do
      # The file name comes out of the user-data, so it is printed as %q
      # quotes it: a line feed in it would start a line of its own, and a
      # control byte, a C1 one in UTF-8 among them, would rewrite a console.
      # %q writes a name with such a byte as $'...' with the byte escaped,
      # and no two names alike. grep is kept quiet with -s because its
      # message for an entry it cannot read, a directory or a dangling link,
      # holds the raw name; the entry is skipped and named below.
      printf -v shownFile '%q' "$file"
      if [ "$(grep -s -c -e '-----BEGIN ' "$file")" = 1 ] &&
          pem=$(openssl x509 -in "$file" -outform PEM 2> /dev/null); then
        printf '%s\n' "$pem" >> "$composed"
        printf 'trusting %s: %s\n' "$shownFile" "$(describe "$file")"
      else
        echo "skipping $shownFile: it must hold exactly one PEM certificate and nothing else" >&2
        skipped=1
      fi
    done

    # Cuts the bundle file into $pieces/<k>.crt, k from 0 to count - 1, one
    # file per block from a line starting -----BEGIN up to the next such
    # line, and has openssl encode each into $pieces/<k>.pem. It sets count
    # to the number of blocks, which the caller loops over. It fails unless
    # the file is a regular one it can read, holds at least one PEM block,
    # every block is a CERTIFICATE one, and openssl parses every block; a
    # block without its END line fails. Text in front of the first block is
    # dropped, and openssl drops text behind a block's END line, as it does
    # in a directory file.
    cutBundle() {
      if ! [ -f "$bundleFile" ] || ! [ -r "$bundleFile" ]; then
        return 1
      fi
      count=$(grep -c -e '-----BEGIN ' "$bundleFile") || return 1
      [ "$(grep -c -e '^-----BEGIN CERTIFICATE-----' "$bundleFile")" = "$count" ] || return 1
      csplit -s -z -f "$pieces/" -b '%d.crt' "$bundleFile" '%^-----BEGIN %' '/^-----BEGIN /' '{*}' || return 1
      for ((k = 0; k < count; k++)); do
        openssl x509 -in "$pieces/$k.crt" -outform PEM -out "$pieces/$k.pem" 2> /dev/null || return 1
      done
    }

    # No fourth argument and a missing bundle file add nothing, and so does
    # a file holding nothing but whitespace. LC_ALL=C makes every other byte
    # count, so a file of bytes the unit's locale cannot decode is skipped
    # instead of taken for blank. Anything else is trusted whole or skipped
    # whole.
    if [ -e "$bundleFile" ]; then
      printf -v shownBundle '%q' "$bundleFile"
      if [ -f "$bundleFile" ] && [ -r "$bundleFile" ] &&
          ! LC_ALL=C grep -q '[^[:space:]]' "$bundleFile"; then
        :
      elif cutBundle; then
        for ((k = 0; k < count; k++)); do
          cat "$pieces/$k.pem" >> "$composed"
          printf 'trusting %s certificate %s: %s\n' "$shownBundle" "$((k + 1))" "$(describe "$pieces/$k.pem")"
        done
      else
        echo "skipping $shownBundle: it must hold one or more PEM certificates and nothing else" >&2
        skipped=1
      fi
    fi

    chmod 0644 "$composed"
    mv -f "$composed" "$output"

    # The bundle is written either way, with every file that passed; the
    # status is what makes systemctl is-failed report a skipped one.
    if [ -n "$skipped" ]; then
      exit 1
    fi
  '';
}
