{ config, lib, ... }:
let
  domain = config.homelab.reverseProxy.baseDomain;
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable;
      message = "The household portal requires the homelab reverse proxy";
    }
    {
      assertion = config.homelab.reverseProxy.enableDnsChallenge;
      message = "The household portal's private HTTPS host requires DNS-01 support";
    }
  ];

  services.caddy.virtualHosts.${domain}.extraConfig = ''
    import private_tls

    root * ${./home-portal}
    encode zstd gzip
    file_server

    header {
      Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
      Referrer-Policy "no-referrer"
      X-Content-Type-Options "nosniff"
      X-Frame-Options "DENY"
      Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    }
  '';
}
