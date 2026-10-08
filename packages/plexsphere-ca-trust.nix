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

writeShellApplication {
  name = "plexsphere-ca-trust";

  runtimeInputs = [ coreutils gnugrep openssl ];

  text = ''
    if [ "$#" -ne 3 ]; then
      echo "usage: plexsphere-ca-trust <system bundle> <certificate directory> <output bundle>" >&2
      exit 2
    fi
    systemBundle=$1
    certificateDirectory=$2
    output=$3

    # Composed beside the output and renamed over it, so no reader sees a
    # partial bundle, and the trap removes the temporary file whichever way
    # the script leaves.
    composed=$(mktemp "$output.XXXXXX")
    trap 'rm -f "$composed"' EXIT

    if ! cat "$systemBundle" > "$composed"; then
      echo "cannot read the system bundle $systemBundle; $output is left as it was" >&2
      exit 1
    fi

    # A missing or empty directory adds nothing.
    shopt -s nullglob
    skipped=
    for file in "$certificateDirectory"/*.crt; do
      # The subject comes out of the certificate, and -nameopt RFC2253
      # escapes its control bytes and every byte above 0x7f, as the installer
      # does with the subject it shows. The file name comes out of the
      # user-data, so it is printed as %q quotes it: a line feed in it would
      # start a line of its own, and a control byte, a C1 one in UTF-8 among
      # them, would rewrite a console. %q writes a name with such a byte as
      # $'...' with the byte escaped, and no two names alike. grep is kept
      # quiet with -s because its message for an entry it cannot read, a
      # directory or a dangling link, holds the raw name; the entry is
      # skipped and named below.
      printf -v shownFile '%q' "$file"
      if [ "$(grep -s -c -e '-----BEGIN ' "$file")" = 1 ] &&
          pem=$(openssl x509 -in "$file" -outform PEM 2> /dev/null); then
        printf '%s\n' "$pem" >> "$composed"
        printf 'trusting %s: %s %s\n' "$shownFile" \
          "$(openssl x509 -in "$file" -noout -subject -nameopt RFC2253)" \
          "$(openssl x509 -in "$file" -noout -fingerprint -sha256)"
      else
        echo "skipping $shownFile: it must hold exactly one PEM certificate and nothing else" >&2
        skipped=1
      fi
    done

    chmod 0644 "$composed"
    mv -f "$composed" "$output"

    # The bundle is written either way, with every file that passed; the
    # status is what makes systemctl is-failed report a skipped one.
    if [ -n "$skipped" ]; then
      exit 1
    fi
  '';
}
