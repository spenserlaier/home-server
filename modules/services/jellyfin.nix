{ config, pkgs, ... }:
let
  domain = config.homelab.reverseProxy.baseDomain;
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable;
      message = "Jellyfin requires the homelab reverse proxy";
    }
    {
      assertion = config.homelab.reverseProxy.enableDnsChallenge;
      message = "Jellyfin's private HTTPS host requires DNS-01 support";
    }
  ];

  services.jellyfin = {
    enable = true;
    openFirewall = false;

    dataDir = "/srv/jellyfin/data";
    configDir = "/srv/jellyfin/config";
    cacheDir = "/srv/jellyfin/cache";
    logDir = "/var/log/jellyfin";

    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      device = "/dev/dri/renderD128";
    };
    forceEncodingConfig = true;
    transcoding = {
      enableHardwareEncoding = true;
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        mpeg2 = true;
        vc1 = true;
        vp8 = true;
        vp9 = true;
      };
      hardwareEncodingCodecs.hevc = true;
      throttleTranscoding = true;
    };
  };

  users = {
    groups.media = { };
    users = {
      jellyfin.extraGroups = [
        "media"
        "render"
        "video"
      ];
      spenser-admin.extraGroups = [ "media" ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /srv/jellyfin 0750 jellyfin jellyfin - -"
    "d /srv/media 0750 root media - -"
    "d /srv/media/movies 2750 root media - -"
    "d /srv/media/tv 2750 root media - -"
  ];

  systemd.services.jellyfin = {
    unitConfig.RequiresMountsFor = [ "/srv/media" ];
    serviceConfig.ReadOnlyPaths = [ "/srv/media" ];
  };

  environment.systemPackages = [ pkgs.libva-utils ];

  services.caddy.virtualHosts."jellyfin.${domain}".extraConfig = ''
    import private_tls
    reverse_proxy 127.0.0.1:8096
  '';
}
