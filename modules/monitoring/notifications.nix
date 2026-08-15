{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = config.homelab.reverseProxy.baseDomain;
  ntfyHost = "ntfy.${domain}";
  ntfyTopic = "homeserver-alerts";
  ntfyListenAddress = "127.0.0.1:2586";
  healthchecksState = "/var/lib/homelab-monitoring/healthchecks.json";
  healthchecksApi = "https://healthchecks.io/api/v3/checks/";

  bootstrapNtfy = pkgs.writeShellApplication {
    name = "bootstrap-ntfy";
    runtimeInputs = [
      pkgs.coreutils
      config.services.ntfy-sh.package
    ];
    text = ''
      ntfy() {
        command ntfy "$1" --config /etc/ntfy/server.yml "''${@:2}"
      }

      ready=false
      for _ in $(seq 1 30); do
        if ntfy user list >/dev/null 2>&1; then
          ready=true
          break
        fi
        sleep 1
      done
      [[ "$ready" == true ]] || {
        echo "ntfy authentication database did not become ready within 30 seconds" >&2
        exit 1
      }

      NTFY_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/publisher-password")"
      export NTFY_PASSWORD
      ntfy user add --ignore-exists homelab-monitoring
      ntfy user change-pass homelab-monitoring

      NTFY_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/subscriber-password")"
      export NTFY_PASSWORD
      ntfy user add --ignore-exists spenser-phone
      ntfy user change-pass spenser-phone
      unset NTFY_PASSWORD

      ntfy access homelab-monitoring ${lib.escapeShellArg ntfyTopic} write-only
      ntfy access spenser-phone ${lib.escapeShellArg ntfyTopic} read-only
      ntfy access everyone ${lib.escapeShellArg ntfyTopic} deny
    '';
  };

  sendNtfyAlert = pkgs.writeShellApplication {
    name = "send-homelab-ntfy-alert";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      if [[ $# -lt 2 ]]; then
        echo "Usage: send-homelab-ntfy-alert KEY MESSAGE..." >&2
        exit 2
      fi
      key="$1"
      shift
      curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        --netrc-file ${lib.escapeShellArg config.sops.templates."ntfy-publisher.netrc".path} \
        --header "Title: Home server: $key" \
        --header "Priority: high" \
        --header "Tags: warning" \
        --data-binary "$*" \
        http://${ntfyListenAddress}/${ntfyTopic}
    '';
  };

  reconcileHealthchecks = pkgs.writeShellApplication {
    name = "reconcile-homelab-healthchecks";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      umask 0077
      work_dir="$(mktemp --directory --tmpdir=/run homelab-healthchecks.XXXXXX)"
      trap 'rm -rf -- "$work_dir"' EXIT

      api_key="$(<"$CREDENTIALS_DIRECTORY/api-key")"
      [[ "$api_key" != *$'\n'* && "$api_key" != *'"'* ]] || {
        echo "Healthchecks API key contains unsupported characters" >&2
        exit 1
      }
      printf 'header = "X-Api-Key: %s"\n' "$api_key" >"$work_dir/curl.conf"
      unset api_key

      host_payload="$(jq --null-input --compact-output '
        {
          name: "Home server heartbeat",
          slug: "homeserver-heartbeat",
          tags: "homeserver infrastructure",
          desc: "Five-minute heartbeat from the NixOS home server",
          timeout: 300,
          grace: 600,
          methods: "POST",
          channels: "*",
          unique: ["slug"]
        }
      ')"
      backup_payload="$(jq --null-input --compact-output \
        --arg schedule ${lib.escapeShellArg config.homelab.backup.kopia.schedule} '
        {
          name: "Home server Kopia backup",
          slug: "homeserver-kopia-backup",
          tags: "homeserver backup",
          desc: "Daily coherent Kopia generation after all native producers succeed",
          schedule: $schedule,
          tz: "America/New_York",
          grace: 7200,
          methods: "POST",
          channels: "*",
          unique: ["slug"]
        }
      ')"

      curl --config "$work_dir/curl.conf" --fail --silent --show-error \
        --request POST --header 'Content-Type: application/json' \
        --data "$host_payload" --output "$work_dir/host.json" \
        ${lib.escapeShellArg healthchecksApi}
      curl --config "$work_dir/curl.conf" --fail --silent --show-error \
        --request POST --header 'Content-Type: application/json' \
        --data "$backup_payload" --output "$work_dir/backup.json" \
        ${lib.escapeShellArg healthchecksApi}

      jq --exit-status -n \
        --slurpfile host "$work_dir/host.json" \
        --slurpfile backup "$work_dir/backup.json" '
          ($host[0].ping_url | startswith("https://hc-ping.com/")) and
          ($backup[0].ping_url | startswith("https://hc-ping.com/"))
        ' >/dev/null
      jq --null-input \
        --slurpfile host "$work_dir/host.json" \
        --slurpfile backup "$work_dir/backup.json" '
          { heartbeat: $host[0].ping_url, kopia_backup: $backup[0].ping_url }
        ' >"$work_dir/healthchecks.json"
      chmod 0600 "$work_dir/healthchecks.json"
      mv -- "$work_dir/healthchecks.json" ${lib.escapeShellArg healthchecksState}
      echo "Reconciled managed Healthchecks.io checks"
    '';
  };

  pingHealthchecks = pkgs.writeShellApplication {
    name = "ping-homelab-healthchecks";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      systemd
    ];
    text = ''
      if [[ $# -lt 2 || $# -gt 3 ]]; then
        echo "Usage: ping-homelab-healthchecks CHECK start|success|fail [required]" >&2
        exit 2
      fi
      check="$1"
      signal="$2"
      required="''${3:-best-effort}"
      case "$check" in
        heartbeat|kopia_backup) ;;
        *) echo "Unknown Healthchecks check: $check" >&2; exit 2 ;;
      esac
      case "$signal" in
        start) suffix="/start" ;;
        success) suffix="" ;;
        fail) suffix="/fail" ;;
        *) echo "Unknown Healthchecks signal: $signal" >&2; exit 2 ;;
      esac

      if [[ ! -s ${lib.escapeShellArg healthchecksState} ]]; then
        message="Healthchecks runtime state is unavailable; reconciliation has not succeeded"
        systemd-cat --identifier=homelab-healthchecks --priority=warning echo "$message"
        [[ "$required" == "required" ]] && exit 1 || exit 0
      fi

      url="$(jq --exit-status --raw-output --arg check "$check" '.[$check]' \
        ${lib.escapeShellArg healthchecksState})" || {
        [[ "$required" == "required" ]] && exit 1 || exit 0
      }
      [[ "$url" =~ ^https://hc-ping\.com/[0-9a-f-]+$ ]] || {
        echo "Refusing unexpected Healthchecks ping URL" >&2
        [[ "$required" == "required" ]] && exit 1 || exit 0
      }

      config_file="$(mktemp --tmpdir=/run homelab-healthchecks-ping.XXXXXX)"
      trap 'rm -f -- "$config_file"' EXIT
      chmod 0600 "$config_file"
      printf 'url = "%s%s"\n' "$url" "$suffix" >"$config_file"
      unset url
      if curl --config "$config_file" --fail --silent --show-error \
        --max-time 15 --request POST; then
        exit 0
      fi

      systemd-cat --identifier=homelab-healthchecks --priority=warning \
        echo "Failed to send $signal signal for $check"
      [[ "$required" == "required" ]] && exit 1 || exit 0
    '';
  };
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable;
      message = "ntfy requires the homelab reverse proxy";
    }
    {
      assertion = config.homelab.reverseProxy.enableDnsChallenge;
      message = "ntfy's private HTTPS host requires DNS-01 support";
    }
    {
      assertion = config.homelab.backup.kopia.enable;
      message = "Healthchecks backup signaling requires Kopia backups";
    }
  ];

  homelab.monitoring.alertDeliveryCommand = lib.getExe sendNtfyAlert;

  services = {
    ntfy-sh = {
      enable = true;
      settings = {
        base-url = "https://${ntfyHost}";
        listen-http = ntfyListenAddress;
        auth-default-access = "deny-all";
        behind-proxy = true;
        enable-login = true;
        cache-duration = "12h";
      };
    };

    caddy.virtualHosts.${ntfyHost}.extraConfig = ''
      import private_tls
      reverse_proxy ${ntfyListenAddress}
    '';
  };

  sops = {
    secrets = {
      "ntfy/publisher_password" = {
        sopsFile = ../../secrets/homeserver.yaml;
      };
      "ntfy/subscriber_password" = {
        sopsFile = ../../secrets/homeserver.yaml;
      };
      "healthchecks/api_key" = {
        sopsFile = ../../secrets/homeserver.yaml;
      };
    };
    templates."ntfy-publisher.netrc" = {
      mode = "0400";
      content = ''
        machine 127.0.0.1
        login homelab-monitoring
        password ${config.sops.placeholder."ntfy/publisher_password"}
      '';
    };
  };

  systemd.services = {
    ntfy-bootstrap = {
      description = "Reconcile ntfy users and topic permissions";
      wantedBy = [ "multi-user.target" ];
      requires = [ "ntfy-sh.service" ];
      after = [ "ntfy-sh.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = config.services.ntfy-sh.user;
        Group = config.services.ntfy-sh.group;
        UMask = "0077";
        StateDirectory = "ntfy-sh";
        LoadCredential = [
          "publisher-password:${config.sops.secrets."ntfy/publisher_password".path}"
          "subscriber-password:${config.sops.secrets."ntfy/subscriber_password".path}"
        ];
        ExecStart = lib.getExe bootstrapNtfy;
      };
    };

    healthchecks-reconcile = {
      description = "Reconcile externally hosted Healthchecks.io checks";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        UMask = "0077";
        LoadCredential = [
          "api-key:${config.sops.secrets."healthchecks/api_key".path}"
        ];
        ExecStart = lib.getExe reconcileHealthchecks;
      };
    };

    healthchecks-heartbeat = {
      description = "Signal that the home server is online";
      wants = [ "network-online.target" ];
      after = [
        "healthchecks-reconcile.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pingHealthchecks} heartbeat success required";
      };
    };

    healthchecks-kopia-failure = {
      description = "Signal Kopia backup failure to Healthchecks.io";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pingHealthchecks} kopia_backup fail";
      };
    };

    kopia-backup = {
      unitConfig.OnFailure = lib.mkAfter [ "healthchecks-kopia-failure.service" ];
      serviceConfig = {
        ExecStartPre = lib.mkAfter [ "${lib.getExe pingHealthchecks} kopia_backup start" ];
        ExecStartPost = lib.mkAfter [ "${lib.getExe pingHealthchecks} kopia_backup success" ];
      };
    };
  };

  systemd.timers = {
    healthchecks-reconcile = {
      description = "Daily reconciliation of managed Healthchecks.io checks";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
    healthchecks-heartbeat = {
      description = "Five-minute external home-server heartbeat";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:0/5:00";
        Persistent = true;
        RandomizedDelaySec = "30s";
      };
    };
  };
}
