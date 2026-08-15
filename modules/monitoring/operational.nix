{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.monitoring;
  alertStateDir = "/var/lib/homelab-alerts";
  monitoringStateDir = "/var/lib/homelab-monitoring";
  backupSuccessMarker = "${monitoringStateDir}/kopia-backup-success";

  recordAlert = pkgs.writeShellApplication {
    name = "record-homelab-alert";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      util-linux
    ];
    text = ''
      if [[ $# -lt 2 ]]; then
        echo "Usage: record-homelab-alert KEY MESSAGE..." >&2
        exit 2
      fi

      key="$1"
      shift
      [[ "$key" =~ ^[A-Za-z0-9_.@-]+$ ]] || {
        echo "Alert key contains unsupported characters" >&2
        exit 2
      }

      message="$*"
      timestamp="$(date --utc --iso-8601=seconds)"
      temporary="$(mktemp --tmpdir=${lib.escapeShellArg alertStateDir} ".''${key}.XXXXXX")"
      trap 'rm -f -- "$temporary"' EXIT
      chmod 0600 "$temporary"
      printf 'time=%s\nkey=%s\nmessage=%s\n' "$timestamp" "$key" "$message" >"$temporary"
      mv -- "$temporary" ${lib.escapeShellArg alertStateDir}/"$key"
      trap - EXIT

      systemd-cat --identifier=homelab-alert --priority=err \
        printf '%s: %s\n' "$key" "$message"
      printf 'HOME SERVER ALERT: %s: %s\n' "$key" "$message" | wall --nobanner || true
      ${lib.optionalString (cfg.alertDeliveryCommand != null) ''
        if ! ${cfg.alertDeliveryCommand} "$key" "$message"; then
          systemd-cat --identifier=homelab-alert --priority=warning \
            printf 'External delivery failed for alert %s\n' "$key"
        fi
      ''}
    '';
  };

  clearAlert = pkgs.writeShellApplication {
    name = "clear-homelab-alert";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [[ $# -ne 1 || ! "$1" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        echo "Usage: clear-homelab-alert KEY" >&2
        exit 2
      fi
      rm -f -- ${lib.escapeShellArg alertStateDir}/"$1"
    '';
  };

  listAlerts = pkgs.writeShellApplication {
    name = "list-homelab-alerts";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
    ];
    text = ''
      if [[ $# -ne 0 ]]; then
        echo "Usage: list-homelab-alerts" >&2
        exit 2
      fi

      mapfile -d $'\0' alerts < <(find ${lib.escapeShellArg alertStateDir} \
        -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
      if [[ ''${#alerts[@]} -eq 0 ]]; then
        echo "No active home-server alerts"
        exit 0
      fi

      for alert in "''${alerts[@]}"; do
        cat -- "$alert"
        echo
      done
      exit 1
    '';
  };

  unitFailure = pkgs.writeShellApplication {
    name = "record-homelab-unit-failure";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if [[ $# -ne 1 ]]; then
        echo "Usage: record-homelab-unit-failure UNIT" >&2
        exit 2
      fi
      unit="$1"
      result="$(systemctl show --property=Result --value "$unit" 2>/dev/null || true)"
      ${lib.getExe recordAlert} "unit-$unit" "$unit failed (result=''${result:-unknown})"
    '';
  };

  checkDiskSpace = pkgs.writeShellApplication {
    name = "check-homelab-disk-space";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      usage="$(df --output=pcent /srv | tail -n 1 | tr -d ' %')"
      [[ "$usage" =~ ^[0-9]+$ ]] || {
        echo "Could not determine /srv filesystem usage" >&2
        exit 1
      }
      if (( usage >= 80 )); then
        echo "Shared Btrfs filesystem is ''${usage}% full (threshold: 80%)" >&2
        exit 1
      fi
      echo "Shared Btrfs filesystem usage is ''${usage}%"
    '';
  };

  checkBackupFreshness = pkgs.writeShellApplication {
    name = "check-homelab-backup-freshness";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      marker=${lib.escapeShellArg backupSuccessMarker}
      [[ -f "$marker" && ! -L "$marker" ]] || {
        echo "No successful Kopia backup has been recorded since monitoring was deployed" >&2
        exit 1
      }

      now="$(date +%s)"
      modified="$(stat --format=%Y "$marker")"
      age_hours="$(( (now - modified) / 3600 ))"
      if (( age_hours > 36 )); then
        echo "Last successful Kopia backup is ''${age_hours} hours old (maximum: 36)" >&2
        exit 1
      fi
      echo "Last successful Kopia backup is ''${age_hours} hours old"
    '';
  };

  recordBackupSuccess = pkgs.writeShellApplication {
    name = "record-kopia-backup-success";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      touch ${lib.escapeShellArg backupSuccessMarker}
    '';
  };

  smartAlert = pkgs.writeShellApplication {
    name = "record-homelab-smart-alert";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      device="''${SMARTD_DEVICE:-unknown-device}"
      key="smart-$(printf '%s' "$device" | tr -c 'A-Za-z0-9_.@-' '-')"
      ${lib.getExe recordAlert} "$key" \
        "SMART warning for ''${SMARTD_DEVICESTRING:-$device}: ''${SMARTD_MESSAGE:-unknown warning}"
    '';
  };

  monitoredUnits = [
    "healthchecks-heartbeat"
    "healthchecks-reconcile"
    "invoiceshelf-backup"
    "jellyfin-backup"
    "kopia-backup"
    "kopia-verify"
    "ntfy-bootstrap"
    "ntfy-sh"
    "paperless-exporter"
  ];
in
{
  options.homelab.monitoring.alertDeliveryCommand = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Optional executable called with an alert key and message after the alert
      has been recorded locally. Delivery failure never suppresses the durable
      local alert.
    '';
  };

  config = lib.mkMerge [
    {
      systemd.tmpfiles.rules = [
        "d ${alertStateDir} 0700 root root - -"
        "d ${monitoringStateDir} 0700 root root - -"
      ];

      services.smartd = {
        enable = true;
        autodetect = true;
        defaults.monitored = "-a -m <nomailer> -M exec ${lib.getExe smartAlert}";
        notifications = {
          mail.enable = false;
          wall.enable = false;
          x11.enable = false;
        };
      };

      systemd.services = {
        "homelab-unit-failure@" = {
          description = "Record failure of %i";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe unitFailure} %i";
          };
        };

        homelab-alert-test = {
          description = "Create a test home-server alert";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = ''
              ${lib.getExe recordAlert} delivery-test "Test alert from homeserver"
            '';
          };
        };

        homelab-disk-space-check = {
          description = "Check shared Btrfs filesystem capacity";
          unitConfig.OnFailure = [ "homelab-unit-failure@%n.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe checkDiskSpace;
            ExecStartPost = [
              "+${lib.getExe clearAlert} unit-homelab-disk-space-check.service"
            ];
          };
        };

        homelab-backup-freshness-check = {
          description = "Check age of the last successful Kopia backup";
          unitConfig.OnFailure = [ "homelab-unit-failure@%n.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe checkBackupFreshness;
            ExecStartPost = [
              "+${lib.getExe clearAlert} unit-homelab-backup-freshness-check.service"
            ];
          };
        };
      };

      systemd.timers = {
        homelab-disk-space-check = {
          description = "Daily shared-filesystem capacity check";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 07:00:00";
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
        };
        homelab-backup-freshness-check = {
          description = "Daily Kopia backup freshness check";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 08:00:00";
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
        };
      };

      environment.systemPackages = [
        clearAlert
        listAlerts
      ];
    }

    {
      systemd.services = lib.genAttrs monitoredUnits (name: {
        unitConfig.OnFailure = [ "homelab-unit-failure@%n.service" ];
        serviceConfig.ExecStartPost = [
          "+${lib.getExe clearAlert} unit-${name}.service"
        ]
        ++ lib.optional (name == "kopia-backup") (lib.getExe recordBackupSuccess);
      });
    }
  ];
}
