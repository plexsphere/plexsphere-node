{ lib, pkgs, modulesPath, ... }:

{
  # nixpkgs' minimal installation CD, unchanged: it already boots on UEFI and
  # BIOS, scans for the hardware of a machine nobody has seen yet, and logs a
  # console in automatically. Everything this module adds is the console hint
  # naming the install script and the two names an operator has to recognise
  # on a burnt medium.
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  # services.getty.helpLine is types.lines, so this is concatenated with the
  # text installation-device.nix already prints below the welcome line
  # rather than replacing it — the hints about the empty account passwords
  # and about `nmtui` stay, and this lands on its own line underneath them.
  # Without it nothing on the console names the script and the medium looks
  # like a stock NixOS installer.
  services.getty.helpLine =
    "Run 'sudo plexsphere-install' to install a Plexsphere node onto this machine.";

  # image.baseName is what iso-image.nix interpolates into the ISO file name
  # (isoName = "${config.image.baseName}.iso"), so this decides that the
  # build lands at result/iso/plexsphere-node-installer-<system>.iso.
  # mkForce is required, not decoration: iso-image.nix sets image.baseName
  # as a plain definition, so a plain definition here collides with it.
  image.baseName = lib.mkForce "plexsphere-node-installer-${pkgs.stdenv.hostPlatform.system}";

  # Stage 1 mounts the medium by this label, and it is what an operator sees
  # when the stick is plugged into a running machine. Plain, not mkForce:
  # iso-image.nix gives volumeID an option default and no definition.
  #
  # 22 characters on x86_64 and 23 on aarch64, against the 32-byte ISO 9660
  # limit iso-image.nix asserts on. The count is worth writing down because
  # the two architectures differ: a volume ID grown past the limit would
  # keep building here and fail only for the longer processor name.
  isoImage.volumeID = "plexsphere-node-${pkgs.stdenv.hostPlatform.uname.processor}";
}
