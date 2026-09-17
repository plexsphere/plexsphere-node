{ lib, stdenvNoCC, fetchurl }:

# The release binaries are statically linked (Go, CGO_ENABLED=0), so no
# ELF patching is required.

let
  version = "0.7.0";
  sources = {
    x86_64-linux = fetchurl {
      url = "https://github.com/plexsphere/plexd/releases/download/v${version}/plexd-linux-amd64";
      hash = "sha256-6C/Yfwa/pSFftAUEQQW2EN94HXPFmtHHXZYQZp8ZdU4=";
    };
    aarch64-linux = fetchurl {
      url = "https://github.com/plexsphere/plexd/releases/download/v${version}/plexd-linux-arm64";
      hash = "sha256-l7n5ZjrHo6bviPDCbGYNwD5fFTlVGnq3Gqim0UakWls=";
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
