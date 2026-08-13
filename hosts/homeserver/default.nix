{ lib, ... }:
{
  imports = [
    ./networking.nix
    ./storage.nix
    ../../modules/base/firewall.nix
    ../../modules/base/persistent-state.nix
    ../../modules/base/secrets.nix
    ../../modules/base/server.nix
    ../../modules/base/users.nix
    ../../modules/networking/reverse-proxy.nix
  ]
  # Generate this file on the physical machine before its first install. A
  # conditional import keeps remote evaluation possible until then.
  ++ lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix;

  networking.hostName = "homeserver";

  homelab.reverseProxy = {
    enable = true;
    baseDomain = "home.hyrax.fyi";

    # Enable after creating the Porkbun credentials described in
    # docs/networking.md and wiring its rendered environment file here.
    enableDnsChallenge = false;
  };

  nixpkgs.hostPlatform = "x86_64-linux";

  # Keep this at the release used for the first installation. It controls
  # stateful defaults and is not an indication of the currently pinned release.
  system.stateVersion = "26.05";
}
