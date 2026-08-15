{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.pihole;
  domain = config.homelab.reverseProxy.baseDomain;
  hostName = "pihole.${domain}";
  stateDir = "/srv/pihole";
  containerName = "pihole";
  webPort = 8092;
  image = "docker.io/pihole/pihole:2026.07.2@sha256:f7d1be836e3bc608b56d82fc9904f5a831cdfbc0dc9c6d58f94e4c985c70038b";

  dnsRecords = [
    "${cfg.lanAddress} homeserver.home.arpa caddy.${domain} jellyfin.${domain} paperless.${domain} invoices.${domain} ntfy.${domain} ${hostName}"
    "192.168.4.38 scanner.home.arpa"
  ];

  checkDns = pkgs.writeShellApplication {
    name = "check-homelab-pihole-dns";
    runtimeInputs = with pkgs; [
      bind.dnsutils
      coreutils
      gnugrep
    ];
    text = ''
      local_answer="$(dig +short +time=3 +tries=1 \
        @${lib.escapeShellArg cfg.lanAddress} ${lib.escapeShellArg hostName} A)"
      grep --fixed-strings --line-regexp ${lib.escapeShellArg cfg.lanAddress} \
        <<<"$local_answer" >/dev/null || {
        echo "Pi-hole returned an unexpected address for ${hostName}" >&2
        exit 1
      }

      external_answer="$(dig +short +time=3 +tries=1 \
        @${lib.escapeShellArg cfg.lanAddress} example.com A)"
      [[ -n "$external_answer" ]] || {
        echo "Pi-hole did not resolve an external test name" >&2
        exit 1
      }

      echo "Pi-hole resolved local and external test names"
    '';
  };
in
{
  options.homelab.pihole = {
    enable = lib.mkEnableOption "the LAN Pi-hole resolver";

    lanAddress = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.10";
      description = "Router-reserved homeserver IPv4 address on which DNS is published.";
    };

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "1.0.0.1"
      ];
      description = "Upstream recursive DNS servers used by Pi-hole.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.homelab.reverseProxy.enable;
        message = "Pi-hole requires the homelab reverse proxy";
      }
      {
        assertion = config.homelab.reverseProxy.enableDnsChallenge;
        message = "Pi-hole's private HTTPS host requires DNS-01 support";
      }
      {
        assertion = cfg.upstreams != [ ];
        message = "Pi-hole requires at least one upstream DNS server";
      }
    ];

    virtualisation = {
      podman.enable = true;
      oci-containers = {
        backend = "podman";
        containers.${containerName} = {
          inherit image;
          environment = {
            TZ = "America/New_York";
            FTLCONF_dns_upstreams = lib.concatStringsSep "\n" cfg.upstreams;
            FTLCONF_dns_listeningMode = "ALL";
            FTLCONF_dns_hosts = lib.concatStringsSep "\n" dnsRecords;
            FTLCONF_dns_domain_name = "home.arpa";
            FTLCONF_dns_domain_local = "true";
            FTLCONF_dns_domainNeeded = "true";
            FTLCONF_dhcp_active = "false";
            FTLCONF_ntp_ipv4_active = "false";
            FTLCONF_ntp_ipv6_active = "false";
            FTLCONF_ntp_sync_active = "false";
            FTLCONF_webserver_domain = hostName;
            FTLCONF_webserver_port = "80";
            FTLCONF_database_maxDBdays = "30";
            WEBPASSWORD_FILE = "/run/secrets/pihole-admin-password";
          };
          volumes = [
            "${stateDir}:/etc/pihole"
            "${config.sops.secrets."pihole/admin_password".path}:/run/secrets/pihole-admin-password:ro"
          ];
          ports = [
            "${cfg.lanAddress}:53:53/tcp"
            "${cfg.lanAddress}:53:53/udp"
            "127.0.0.1:${toString webPort}:80/tcp"
          ];
        };
      };
    };

    services.caddy.virtualHosts.${hostName}.extraConfig = ''
      import private_tls
      reverse_proxy 127.0.0.1:${toString webPort}
    '';

    networking.firewall = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };

    sops.secrets."pihole/admin_password" = {
      sopsFile = ../../secrets/homeserver.yaml;
      mode = "0400";
      restartUnits = [ "podman-${containerName}.service" ];
    };

    systemd = {
      tmpfiles.rules = [ "d ${stateDir} 0750 root root - -" ];

      services = {
        "podman-${containerName}" = {
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig.Restart = lib.mkForce "on-failure";
        };

        pihole-dns-check = {
          description = "Verify Pi-hole local and upstream DNS resolution";
          requires = [ "podman-${containerName}.service" ];
          after = [ "podman-${containerName}.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe checkDns;
          };
        };
      };

      timers.pihole-dns-check = {
        description = "Five-minute Pi-hole DNS health check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = "5m";
          RandomizedDelaySec = "30s";
        };
      };
    };
  };
}
