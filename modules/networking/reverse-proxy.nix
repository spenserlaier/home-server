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

    porkbunEnvironmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets-rendered/caddy-porkbun.env";
      description = ''
        Runtime environment file containing PORKBUN_API_KEY and
        PORKBUN_API_SECRET_KEY. The file must not be stored in the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.enableDnsChallenge -> cfg.porkbunEnvironmentFile != null;
        message = ''
          homelab.reverseProxy.enableDnsChallenge requires
          homelab.reverseProxy.porkbunEnvironmentFile
        '';
      }
    ];

    services.caddy = {
      enable = true;
      package = caddyWithPorkbun;
      environmentFile = lib.mkIf cfg.enableDnsChallenge cfg.porkbunEnvironmentFile;
      openFirewall = false;

      globalConfig = lib.optionalString cfg.enableDnsChallenge ''
        acme_dns porkbun {
          api_key {env.PORKBUN_API_KEY}
          api_secret_key {env.PORKBUN_API_SECRET_KEY}
        }
      '';

      virtualHosts."caddy.${cfg.baseDomain}" = {
        hostName =
          if cfg.enableDnsChallenge then "caddy.${cfg.baseDomain}" else "http://caddy.${cfg.baseDomain}";
        extraConfig = ''
          respond /healthz "ok" 200
          abort
        '';
      };
    };

    networking.firewall = {
      allowedTCPPorts = [ 80 ] ++ lib.optional cfg.enableDnsChallenge 443;
      allowedUDPPorts = lib.optional cfg.enableDnsChallenge 443;
    };
  };
}
