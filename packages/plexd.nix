{ lib, stdenvNoCC, fetchurl }:

# The release binaries are statically linked (Go, CGO_ENABLED=0), so no
# ELF patching is required.

let
  version = "0.29.0";
  sources = {
    x86_64-linux = fetchurl {
      url = "https://github.com/plexsphere/plexd/releases/download/v${version}/plexd-linux-amd64";
      hash = "sha256-2gEronhCLw5FfvUP2GV+hsGY2cCgaWDcBqNn+C0kKyo=";
    };
    aarch64-linux = fetchurl {
      url = "https://github.com/plexsphere/plexd/releases/download/v${version}/plexd-linux-arm64";
      hash = "sha256-J1rdXP2WT7CCVzindSX8tU1yCqMcYytESPn00SAyppg=";
    };
  };
in
stdenvNoCC.mkDerivation {
  pname = "plexd";
  inherit version;

  src = sources.${stdenvNoCC.hostPlatform.system} or (throw "plexd: unsupported system ${stdenvNoCC.hostPlatform.system}; supported: ${lib.concatStringsSep ", " (lib.attrNames sources)}");

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/plexd
    runHook postInstall
  '';

  # Every pinned fetch, not just the one for this host platform, so CI can
  # realize both hashes (and verify both signatures) on a single runner.
  passthru.sources = sources;

  meta = {
    description = "Plexsphere node agent";
    homepage = "https://github.com/plexsphere/plexd";
    license = lib.licenses.asl20;
    platforms = lib.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "plexd";
  };
}
