{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = config.homelab.reverseProxy.baseDomain;
  hostName = "audiobookshelf.${domain}";
  stateRoot = "/srv/audiobookshelf";
  mediaRoot = "/srv/media/audiobooks";
  backupDir = "/srv/backups/services/audiobookshelf";

  backupAudiobookshelf = pkgs.writeShellApplication {
    name = "backup-service-audiobookshelf";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      gnutar
      gzip
    ];
    text = ''
      if [[ $EUID -ne 0 ]]; then
        echo "This command must run as root" >&2
        exit 1
      fi
      if [[ $# -ne 0 ]]; then
        echo "Usage: backup-service-audiobookshelf" >&2
        exit 2
      fi

      timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"
      archive=${lib.escapeShellArg backupDir}/audiobookshelf-state-"$timestamp".tar.gz
      temporary_archive="$archive.incomplete"
      service_was_active=false

      cleanup() {
        rm -f -- "$temporary_archive"
        if [[ "$service_was_active" == true ]]; then
          systemctl start audiobookshelf.service
        fi
      }
      trap cleanup EXIT

      if systemctl is-active --quiet audiobookshelf.service; then
        service_was_active=true
        systemctl stop audiobookshelf.service
      fi

      tar --create --gzip --file "$temporary_archive" \
        --directory ${lib.escapeShellArg stateRoot} \
        --exclude='./metadata/cache' \
        --exclude='./metadata/logs' \
        config metadata
      tar --list --gzip --file "$temporary_archive" >/dev/null
      mv -- "$temporary_archive" "$archive"

      find ${lib.escapeShellArg backupDir} \
        -maxdepth 1 -type f -name 'audiobookshelf-state-*.tar.gz' \
        -mtime +7 -delete

      echo "Created Audiobookshelf backup: $archive"
    '';
  };
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable;
      message = "Audiobookshelf requires the homelab reverse proxy";
    }
    {
      assertion = config.homelab.reverseProxy.enableDnsChallenge;
      message = "Audiobookshelf's private HTTPS host requires DNS-01 support";
    }
  ];

  services = {
    audiobookshelf = {
      enable = true;
      host = "127.0.0.1";
      port = 8000;
      openFirewall = false;
    };

    caddy.virtualHosts.${hostName}.extraConfig = ''
      import private_tls
      reverse_proxy 127.0.0.1:${toString config.services.audiobookshelf.port}
    '';
  };

  users.users = {
    audiobookshelf.extraGroups = [ "media" ];
    spenser-admin.extraGroups = [ "media" ];
  };

  systemd = {
    tmpfiles.settings."00-homelab-audiobookshelf" = {
      ${stateRoot}.d = {
        mode = "0750";
        user = "audiobookshelf";
        group = "audiobookshelf";
      };
      "${stateRoot}/config".d = {
        mode = "0750";
        user = "audiobookshelf";
        group = "audiobookshelf";
      };
      "${stateRoot}/metadata".d = {
        mode = "0750";
        user = "audiobookshelf";
        group = "audiobookshelf";
      };
      ${mediaRoot}.d = {
        mode = "2750";
        user = "root";
        group = "media";
      };
      ${backupDir}.d = {
        mode = "0750";
        user = "root";
        group = "homelab-backup";
      };
    };

    services = {
      audiobookshelf = {
        unitConfig.RequiresMountsFor = [ mediaRoot ];
        serviceConfig = {
          StateDirectory = lib.mkForce [ ];
          WorkingDirectory = lib.mkForce stateRoot;
          ReadOnlyPaths = [ mediaRoot ];
          ExecStart = lib.mkForce ''
            ${lib.getExe config.services.audiobookshelf.package} \
              --host ${config.services.audiobookshelf.host} \
              --port ${toString config.services.audiobookshelf.port} \
              --config ${stateRoot}/config \
              --metadata ${stateRoot}/metadata
          '';
        };
      };

      audiobookshelf-backup = {
        description = "Create a consistent Audiobookshelf state archive";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe backupAudiobookshelf;
          UMask = "0027";
        };
      };
    };
  };

  environment.systemPackages = [ backupAudiobookshelf ];
}
