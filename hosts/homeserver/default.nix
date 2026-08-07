{
  imports = [
    ./networking.nix
    ./storage.nix
    ../../modules/base/firewall.nix
    ../../modules/base/server.nix
    ../../modules/base/users.nix
  ];

  networking.hostName = "homeserver";

  nixpkgs.hostPlatform = "x86_64-linux";

  # Keep this at the release used for the first installation. It controls
  # stateful defaults and is not an indication of the currently pinned release.
  system.stateVersion = "26.05";
}
