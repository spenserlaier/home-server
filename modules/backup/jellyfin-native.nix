{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.backup.jellyfin;
  archiveDir = "/srv/backups/services/jellyfin";
  nativeBackupDir = "${config.services.jellyfin.dataDir}/backups";

  createBackup = pkgs.writeShellApplication {
    name = "backup-jellyfin";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      jq
      unzip
      util-linux
    ];
    text = ''
      token_file=${lib.escapeShellArg config.sops.secrets."jellyfin/api_key".path}
      archive_dir=${lib.escapeShellArg archiveDir}
      native_dir=${lib.escapeShellArg nativeBackupDir}
      response="$(mktemp)"
      trap 'rm -f "$response"' EXIT

      exec 9>/run/jellyfin-backup/lock
      flock --nonblock 9 || {
        echo "A Jellyfin backup is already running" >&2
        exit 1
      }

      token="$(<"$token_file")"
      [[ -n "$token" ]] || {
        echo "The Jellyfin API key is empty" >&2
        exit 1
      }

      curl_config="header = \"Authorization: MediaBrowser Token=$token\""
      curl_config+=$'\nheader = "Content-Type: application/json"'

      printf '%s\n' "$curl_config" | curl \
        --config - \
        --fail-with-body \
        --silent \
        --show-error \
        --max-time 7200 \
        --request POST \
        --data '{"Database":true,"Metadata":true,"Subtitles":true,"Trickplay":false}' \
        --output "$response" \
        http://127.0.0.1:8096/Backup/Create

      archive="$(jq --exit-status --raw-output '
        select(
          .Options.Database == true and
          .Options.Metadata == true and
          .Options.Subtitles == true and
          .Options.Trickplay == false
        ) | .Path
      ' "$response")"

      case "$archive" in
        "$native_dir"/*.zip) ;;
        *)
          echo "Jellyfin returned an unexpected backup path" >&2
          exit 1
          ;;
      esac

      [[ -f "$archive" && ! -L "$archive" ]] || {
        echo "Jellyfin did not create a regular backup archive" >&2
        exit 1
      }
      unzip -tq "$archive"
      unzip -Z1 "$archive" | grep --fixed-strings --line-regexp 'manifest.json' >/dev/null
      unzip -Z1 "$archive" | grep --fixed-strings --line-regexp 'Database/HistoryRow.json' >/dev/null
      unzip -Z1 "$archive" | grep --extended-regexp '^Config/.+\.(xml|json)$' >/dev/null
      unzip -p "$archive" manifest.json | jq --exit-status '
        .Options.Database == true and
        .Options.Metadata == true and
        .Options.Subtitles == true and
        .Options.Trickplay == false and
        (.ServerVersion | type == "string" and length > 0) and
        (.BackupEngineVersion | type == "string" and length > 0)
      ' >/dev/null

      destination="$archive_dir/$(basename "$archive")"
      mv --no-clobber "$archive" "$destination"
      chmod 0600 "$destination"

      # Keep a small local restore window. Kopia retention will become the
      # authoritative long-term policy when the whole-host generation job is
      # added.
      find "$archive_dir" -maxdepth 1 -type f -name 'jellyfin-backup-*.zip' \
        -mtime +${toString cfg.localRetentionDays} -delete

      echo "Validated Jellyfin backup: $destination"
    '';
  };

  restoreBackup = pkgs.writeShellApplication {
    name = "restore-service-jellyfin";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      systemd
      unzip
      util-linux
    ];
    text = ''
      if [[ $# -ne 1 ]]; then
        echo "Usage: restore-service-jellyfin BACKUP.zip" >&2
        exit 2
      fi
      if [[ $(id -u) -ne 0 ]]; then
        echo "This restore must run as root" >&2
        exit 1
      fi

      archive="$(realpath -e -- "$1")"
      [[ -f "$archive" && ! -L "$archive" ]] || {
        echo "Backup must be a regular file" >&2
        exit 1
      }
      unzip -tq "$archive"

      printf 'Restore Jellyfin from %s? This replaces its current state. [y/N] ' "$archive"
      read -r confirmation
      [[ "$confirmation" == y || "$confirmation" == Y ]] || exit 1

      # Jellyfin 10.11 requires a migrated database before its CLI restore can
      # purge and repopulate tables. Starting the declared service first makes
      # fresh-machine restores non-interactive despite upstream issue #17449.
      systemctl start jellyfin.service
      ready=false
      for _ in $(seq 1 60); do
        if curl --fail --silent --output /dev/null http://127.0.0.1:8096/System/Info/Public; then
          ready=true
          break
        fi
        sleep 1
      done
      [[ "$ready" == true ]] || {
        echo "Jellyfin did not initialize within 60 seconds" >&2
        exit 1
      }
      systemctl stop jellyfin.service
      restart_jellyfin() { systemctl start jellyfin.service; }
      trap restart_jellyfin EXIT

      runuser --user jellyfin -- env XDG_CACHE_HOME=${config.services.jellyfin.cacheDir} \
        ${lib.getExe config.services.jellyfin.package} \
        --datadir ${lib.escapeShellArg config.services.jellyfin.dataDir} \
        --configdir ${lib.escapeShellArg config.services.jellyfin.configDir} \
        --cachedir ${lib.escapeShellArg config.services.jellyfin.cacheDir} \
        --logdir ${lib.escapeShellArg config.services.jellyfin.logDir} \
        --restore-archive "$archive"

      restart_jellyfin
      trap - EXIT
      systemctl is-active --quiet jellyfin.service
    '';
  };
in
{
  options.homelab.backup.jellyfin = {
    enable = lib.mkEnableOption "automated Jellyfin-native backups";
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:15:00";
      description = "systemd OnCalendar expression for native Jellyfin backups.";
    };
    localRetentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Days of validated Jellyfin archives to retain locally.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.jellyfin.enable;
        message = "Jellyfin backups require services.jellyfin.enable";
      }
    ];

    sops.secrets."jellyfin/api_key" = {
      sopsFile = ../../secrets/homeserver.yaml;
      owner = "jellyfin";
      group = "jellyfin";
      mode = "0400";
      restartUnits = [ "jellyfin-backup.service" ];
    };

    systemd.tmpfiles.rules = [
      "d /srv/backups 0750 root homelab-backup - -"
      "d /srv/backups/services 0750 root homelab-backup - -"
      "d ${archiveDir} 0700 jellyfin jellyfin - -"
      "d ${nativeBackupDir} 0700 jellyfin jellyfin - -"
    ];

    users.groups.homelab-backup = { };
    users.users.jellyfin.extraGroups = [ "homelab-backup" ];

    systemd.services.jellyfin-backup = {
      description = "Create and validate a native Jellyfin backup";
      after = [ "jellyfin.service" ];
      requires = [ "jellyfin.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "jellyfin";
        Group = "jellyfin";
        ExecStart = lib.getExe createBackup;
        UMask = "0077";
        RuntimeDirectory = "jellyfin-backup";
        RuntimeDirectoryMode = "0700";
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          nativeBackupDir
          archiveDir
        ];
      };
    };

    systemd.timers.jellyfin-backup = {
      description = "Daily native Jellyfin backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "15m";
        Unit = "jellyfin-backup.service";
      };
    };

    environment.systemPackages = [ restoreBackup ];
  };
}
