{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = config.homelab.reverseProxy.baseDomain;
  hostName = "homebox.${domain}";
  stateRoot = "/srv/homebox";
  databasePath = "${stateRoot}/data/homebox.db";
  backupDir = "/srv/backups/services/homebox";
  port = 7745;
  initializationPort = 7746;

  initializeHomebox = pkgs.writeShellApplication {
    name = "initialize-homebox";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      sqlite
    ];
    text = ''
      if [[ $# -ne 0 ]]; then
        echo "Usage: initialize-homebox" >&2
        exit 2
      fi

      if [[ -f ${lib.escapeShellArg databasePath} ]]; then
        user_count="$(sqlite3 ${lib.escapeShellArg databasePath} 'SELECT count(*) FROM users;' 2>/dev/null || true)"
        if [[ "$user_count" =~ ^[1-9][0-9]*$ ]]; then
          echo "Homebox already has an owner account"
          exit 0
        fi
      fi

      server_pid=
      cleanup() {
        if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
          kill "$server_pid"
          wait "$server_pid" || true
        fi
      }
      trap cleanup EXIT

      ${lib.getExe config.services.homebox.package} &
      server_pid=$!

      status_url=http://127.0.0.1:${toString initializationPort}/api/v1/status
      registration_url=http://127.0.0.1:${toString initializationPort}/api/v1/users/register
      for attempt in {1..30}; do
        if curl --fail --silent --show-error "$status_url" >/dev/null; then
          break
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
          echo "The temporary Homebox initializer exited unexpectedly" >&2
          wait "$server_pid"
        fi
        if [[ "$attempt" -eq 30 ]]; then
          echo "Homebox did not become ready for initialization" >&2
          exit 1
        fi
        sleep 1
      done

      jq --null-input \
        --arg name "Home Admin" \
        --arg email "admin@home.hyrax.fyi" \
        --rawfile password "$CREDENTIALS_DIRECTORY/admin-password" \
        '{name: $name, email: $email, password: $password}' \
        | curl --fail-with-body --silent --show-error \
          --header 'Content-Type: application/json' \
          --data-binary @- \
          "$registration_url" >/dev/null

      cleanup
      server_pid=

      user_count="$(sqlite3 ${lib.escapeShellArg databasePath} 'SELECT count(*) FROM users;')"
      [[ "$user_count" =~ ^[1-9][0-9]*$ ]] || {
        echo "Homebox initialization did not create an owner account" >&2
        exit 1
      }
      echo "Initialized the Homebox owner account"
    '';
  };

  backupHomebox = pkgs.writeShellApplication {
    name = "backup-service-homebox";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gzip
      gnutar
      systemd
    ];
    text = ''
      if [[ $EUID -ne 0 ]]; then
        echo "This command must run as root" >&2
        exit 1
      fi
      if [[ $# -ne 0 ]]; then
        echo "Usage: backup-service-homebox" >&2
        exit 2
      fi

      timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"
      archive=${lib.escapeShellArg backupDir}/homebox-state-"$timestamp".tar.gz
      temporary_archive="$archive.incomplete"
      service_was_active=false

      cleanup() {
        rm -f -- "$temporary_archive"
        if [[ "$service_was_active" == true ]]; then
          systemctl start homebox.service
        fi
      }
      trap cleanup EXIT

      if systemctl is-active --quiet homebox.service; then
        service_was_active=true
        systemctl stop homebox.service
      fi

      tar --create --gzip --file "$temporary_archive" \
        --directory ${lib.escapeShellArg stateRoot} data
      tar --list --gzip --file "$temporary_archive" >/dev/null
      mv -- "$temporary_archive" "$archive"

      find ${lib.escapeShellArg backupDir} \
        -maxdepth 1 -type f -name 'homebox-state-*.tar.gz' \
        -mtime +7 -delete

      echo "Created Homebox backup: $archive"
    '';
  };
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable;
      message = "Homebox requires the homelab reverse proxy";
    }
    {
      assertion = config.homelab.reverseProxy.enableDnsChallenge;
      message = "Homebox's private HTTPS host requires DNS-01 support";
    }
  ];

  services = {
    homebox = {
      enable = true;
      settings = {
        HBOX_WEB_HOST = "127.0.0.1";
        HBOX_WEB_PORT = toString port;
        HBOX_STORAGE_CONN_STRING = "file://${stateRoot}";
        HBOX_STORAGE_PREFIX_PATH = "data";
        HBOX_DATABASE_SQLITE_PATH = "${databasePath}?_pragma=busy_timeout=999&_pragma=journal_mode=WAL&_fk=1&_time_format=sqlite";
        HBOX_OPTIONS_ALLOW_REGISTRATION = "false";
        HBOX_OPTIONS_ALLOW_ANALYTICS = "false";
        HBOX_OPTIONS_TRUST_PROXY = "true";
        HOME = stateRoot;
        TMPDIR = "${stateRoot}/tmp";
      };
    };

    caddy.virtualHosts.${hostName}.extraConfig = ''
      import private_tls
      reverse_proxy 127.0.0.1:${toString port}
    '';
  };

  sops.secrets."homebox/admin_password" = {
    sopsFile = ../../secrets/homeserver.yaml;
    mode = "0400";
  };

  systemd = {
    tmpfiles.settings."00-homelab-homebox" = {
      ${stateRoot}.d = {
        mode = "0750";
        user = "homebox";
        group = "homebox";
      };
      "${stateRoot}/data".d = {
        mode = "0700";
        user = "homebox";
        group = "homebox";
      };
      "${stateRoot}/tmp".d = {
        mode = "0700";
        user = "homebox";
        group = "homebox";
      };
      ${backupDir}.d = {
        mode = "0750";
        user = "root";
        group = "homelab-backup";
      };
    };

    services = {
      caddy = {
        after = [ "homebox-initialize.service" ];
        requires = [ "homebox-initialize.service" ];
      };

      homebox = {
        after = [ "homebox-initialize.service" ];
        requires = [ "homebox-initialize.service" ];
        unitConfig.RequiresMountsFor = [ stateRoot ];
        preStart = lib.mkForce ''
          ${pkgs.coreutils}/bin/rm -rf ${stateRoot}/tmp
          ${pkgs.coreutils}/bin/mkdir -p ${stateRoot}/tmp
        '';
        serviceConfig = {
          StateDirectory = lib.mkForce [ ];
          ReadWritePaths = [ stateRoot ];
        };
      };

      homebox-initialize = {
        description = "Initialize the Homebox owner account";
        wantedBy = [ "multi-user.target" ];
        before = [
          "caddy.service"
          "homebox.service"
        ];
        unitConfig.RequiresMountsFor = [ stateRoot ];
        environment = config.services.homebox.settings // {
          HBOX_OPTIONS_ALLOW_REGISTRATION = "true";
          HBOX_WEB_PORT = toString initializationPort;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "homebox";
          Group = "homebox";
          ExecStart = lib.getExe initializeHomebox;
          LoadCredential = [
            "admin-password:${config.sops.secrets."homebox/admin_password".path}"
          ];
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ stateRoot ];
        };
      };

      homebox-backup = {
        description = "Create a consistent Homebox state archive";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe backupHomebox;
          UMask = "0027";
        };
      };
    };
  };

  environment.systemPackages = [
    backupHomebox
    initializeHomebox
  ];
}
