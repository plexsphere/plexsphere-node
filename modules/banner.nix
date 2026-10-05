{ config, lib, ... }:

let
  # Written out as it appears on the console. ASCII only and 66 columns
  # wide: the same text goes out on a serial console, where neither a font
  # with box-drawing glyphs nor more than 80 columns can be assumed.
  banner = ''
    +----------------------------------------------------------------+
    |                                                                |
    |   ____  _     _______  ______  ____  _   _ _____ ____  _____   |
    |  |  _ \| |   | ____\ \/ / ___||  _ \| | | | ____|  _ \| ____|  |
    |  | |_) | |   |  _|  \  /\___ \| |_) | |_| |  _| | |_) |  _|    |
    |  |  __/| |___| |___ /  \ ___) |  __/|  _  | |___|  _ <| |___   |
    |  |_|   |_____|_____/_/\_\____/|_|   |_| |_|_____|_| \_\_____|  |
    |                                                                |
    +----------------------------------------------------------------+
  '';
in
{
  # The console greeting of everything this repository boots. The installer
  # medium imports this module and the node profile does too, so a machine
  # greets with the same banner before the installation and after it.
  #
  # services.getty.greetingLine is types.str, so unlike helpLine it does not
  # merge with the nixpkgs default: the welcome line is restated here, word
  # for word, to keep it under the banner. getty.nix wraps the whole value
  # in its bold green escape, so the banner takes the welcome line's colour.
  #
  # agetty reads a backslash in /etc/issue as the start of an escape — \m
  # and \l in the welcome line are two — and prints a doubled one as a
  # single backslash. The banner's own are doubled for that reason; left as
  # they are, agetty would swallow them and the letters would come out
  # broken.
  #
  # Priority 900 sits between the two definitions this has to get along
  # with. It outranks the mkDefault getty.nix gives the stock welcome line,
  # which a mkDefault here would collide with, and it gives way to a plain
  # definition, so a host that sets a greeting line of its own keeps it.
  services.getty.greetingLine = lib.mkOverride 900 (
    lib.replaceStrings [ "\\" ] [ "\\\\" ] banner
    + ''<<< Welcome to ${config.system.nixos.distroName} ${config.system.nixos.label} (\m) - \l >>>''
  );
}
