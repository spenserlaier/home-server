{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.reverseProxy;

  caddyWithPorkbun = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/porkbun@v0.3.1" ];
    hash = "sha256-CjL8dMdnsiawaPiQGRvL3he4Ydd3nIbQs6tBWMwUbaw=";
  };
in
{
  options.homelab.reverseProxy = {
    enable = lib.mkEnableOption "the homelab Caddy reverse proxy";

    baseDomain = lib.mkOption {
      type = lib.types.str;
      example = "home.example.com";
      description = "Private DNS suffix used for proxied services.";
    };

    enableDnsChallenge = lib.mkEnableOption "Porkbun DNS-01 certificate issuance";
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      package = caddyWithPorkbun;
      environmentFile = lib.mkIf cfg.enableDnsChallenge config.sops.templates."caddy-porkbun.env".path;
      openFirewall = false;

      extraConfig = lib.optionalString cfg.enableDnsChallenge ''
        (private_tls) {
          tls {
            dns porkbun {
              api_key {env.PORKBUN_API_KEY}
              api_secret_key {env.PORKBUN_API_SECRET_KEY}
            }
            propagation_delay 30s
            propagation_timeout 10m
            resolvers 1.1.1.1 8.8.8.8
          }
        }
      '';

      virtualHosts."caddy.${cfg.baseDomain}" = {
        hostName =
          if cfg.enableDnsChallenge then "caddy.${cfg.baseDomain}" else "http://caddy.${cfg.baseDomain}";
        extraConfig = ''
          ${lib.optionalString cfg.enableDnsChallenge "import private_tls"}
          route {
            respond /healthz "ok" 200
            abort
          }
        '';
      };
    };

    networking.firewall = {
      allowedTCPPorts = [ 80 ] ++ lib.optional cfg.enableDnsChallenge 443;
      allowedUDPPorts = lib.optional cfg.enableDnsChallenge 443;
    };

    sops = lib.mkIf cfg.enableDnsChallenge {
      defaultSopsFile = ../../secrets/homeserver.yaml;
      secrets = {
        "caddy/porkbun_api_key" = { };
        "caddy/porkbun_api_secret_key" = { };
      };
      templates."caddy-porkbun.env" = {
        owner = "caddy";
        group = "caddy";
        mode = "0400";
        content = ''
          PORKBUN_API_KEY=${config.sops.placeholder."caddy/porkbun_api_key"}
          PORKBUN_API_SECRET_KEY=${config.sops.placeholder."caddy/porkbun_api_secret_key"}
        '';
      };
    };
  };
}
