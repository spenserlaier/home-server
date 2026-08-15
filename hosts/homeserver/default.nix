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
    ../../modules/backup/jellyfin-native.nix
    ../../modules/backup/kopia.nix
    ../../modules/monitoring/notifications.nix
    ../../modules/monitoring/operational.nix
    ../../modules/networking/reverse-proxy.nix
    ../../modules/services/invoiceshelf.nix
    ../../modules/services/home-portal.nix
    ../../modules/services/jellyfin.nix
    ../../modules/services/paperless.nix
    ../../modules/services/paperless-scanner.nix
    ../../modules/services/pihole.nix
  ]
  # Generate this file on the physical machine before its first install. A
  # conditional import keeps remote evaluation possible until then.
  ++ lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix;

  networking.hostName = "homeserver";

  # Eero's routed LAN is a /22; clients may use 192.168.4.x through
  # 192.168.7.x even though the server itself is 192.168.4.22.
  homelab.firewall.lanIPv4Subnet = "192.168.4.0/22";

  homelab.reverseProxy = {
    enable = true;
    baseDomain = "home.hyrax.fyi";
    enableDnsChallenge = true;
  };

  homelab.pihole = {
    enable = true;
    lanAddress = "192.168.4.22";
  };

  homelab.backup = {
    jellyfin = {
      enable = true;
      # Kopia starts this unit immediately before each coherent generation.
      enableTimer = false;
    };
    kopia = {
      enable = true;
      bucket = "hyrax-home-server";
      endpoint = "s3.us-east-005.backblazeb2.com";
      region = "us-east-005";
      prepareUnits = [
        "jellyfin-backup.service"
        "paperless-exporter.service"
        "invoiceshelf-backup.service"
      ];
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";

  # Keep this at the release used for the first installation. It controls
  # stateful defaults and is not an indication of the currently pinned release.
  system.stateVersion = "26.05";
}
