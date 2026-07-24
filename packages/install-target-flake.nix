{ writeTextDir, flakeSource }:

# The flake disko-install is pointed at. It exists only as indirection:
# install-cli.nix:10 resolves the install target as
# (builtins.getFlake "${flake}").nixosConfigurations."${flakeAttr}", and this
# repository deliberately exports no nixosConfigurations — its targets live
# under lib.installTargets, where nix flake check leaves them unforced. One
# generated line reconnects the two.
#
# Every property of that line looks like a style choice and every one of them
# breaks the install if changed:
#
#   * No inputs. The generated flake ships inside the ISO and is therefore
#     evaluated from a read-only store path. An input that needed locking
#     would make nix want to write a flake.lock beside it, and disko-install
#     runs every nix invocation with --option no-write-lock-file true
#     (disko-install:43-46), which turns that write into an abort mid-install.
#
#   * flakeSource is interpolated, so the reference below is a runtime store
#     reference and this repository's source is pulled into the closure of the
#     ISO that ships the generated flake — rather than fetched from the
#     network while the install is already running.
#
#   * builtins.getFlake on a store path is legal on the target machine because
#     disko-install builds with --impure and
#     --extra-experimental-features 'nix-command flakes'
#     (disko-install:43-46 and :235-247), which is also why the live medium
#     needs no nix.settings.experimental-features of its own.
#
#   * That inner getFlake resolves against this repository's committed
#     flake.lock, so nixpkgs and disko are fetched on the target machine
#     during the install — the network dependency the whole live-USB path
#     already accepts.

writeTextDir "flake.nix" ''
  { outputs = _: { nixosConfigurations = (builtins.getFlake "${flakeSource}").lib.installTargets; }; }
''
