{
  config,
  lib,
  pkgs,
  ...
}:
let
  hostName = "books.${config.homelab.reverseProxy.baseDomain}";
  stateRoot = "/srv/bookorbit";
  dataDir = "${stateRoot}/data";
  databaseDir = "${stateRoot}/database";
  booksDir = "/srv/media/books";
  backupDir = "/srv/backups/services/bookorbit";
  appContainer = "bookorbit";
  databaseContainer = "bookorbit-database";
  networkName = "bookorbit";
  appImage = "ghcr.io/bookorbit/bookorbit:3.6.0@sha256:bbb5da52e96dbbff1dd36f55454f9845e6cde264b4b3428a3ea783124a4ca62e";
  databaseImage = "docker.io/pgvector/pgvector:pg18@sha256:2358fcba361ed2233a5ed81b5fe4ca779ccb304120ce531a3bf51c0ed7e2bc11";
  # A stable container identity, distinct from existing application identities.
  uid = 1200;
  gid = 1200;

  waitForDatabase = pkgs.writeShellScript "wait-for-bookorbit-database" ''
    set -eu
    for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
      if ${pkgs.podman}/bin/podman exec ${databaseContainer} \
        pg_isready --host=127.0.0.1 --username=bookorbit --dbname=bookorbit >/dev/null 2>&1; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 2
    done
    echo "BookOrbit database did not become ready within 120 seconds" >&2
    exit 1
  '';

  validateBackup = pkgs.writeShellApplication {
    name = "validate-service-bookorbit-backup";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnutar
      jq
      postgresql_18
      zstd
    ];
    text = ''
      if [[ $# -ne 1 ]]; then
        echo "Usage: validate-service-bookorbit-backup GENERATION_DIRECTORY" >&2
        exit 2
      fi
      generation="$(realpath -e -- "$1")"
      for artifact in database.dump files.tar.zst metadata.json SHA256SUMS; do
        [[ -f "$generation/$artifact" && -s "$generation/$artifact" && ! -L "$generation/$artifact" ]] || {
          echo "Missing regular BookOrbit backup artifact: $artifact" >&2
          exit 1
        }
      done
      (cd "$generation"; sha256sum --check --strict SHA256SUMS)
      pg_restore --list "$generation/database.dump" >/dev/null
      listing="$(mktemp)"
      trap 'rm -f -- "$listing"' EXIT
      tar --zstd --list --file "$generation/files.tar.zst" >"$listing"
      grep --extended-regexp '^data(/|$)' "$listing" >/dev/null
      grep --extended-regexp '^books(/|$)' "$listing" >/dev/null
      if grep --extended-regexp '(^/|(^|/)\.\.(/|$))' "$listing"; then
        echo "Unsafe path in BookOrbit backup archive" >&2
        exit 1
      fi
      jq --exit-status '.service == "bookorbit" and .version == "3.6.0" and
        (.app_image | type == "string") and (.database_image | type == "string") and
        (.created_at | type == "string" and length > 0)' "$generation/metadata.json" >/dev/null
      echo "Validated BookOrbit backup: $generation"
    '';
  };

  createBackup = pkgs.writeShellApplication {
    name = "backup-service-bookorbit";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnutar
      jq
      podman
      systemd
      util-linux
      validateBackup
      zstd
    ];
    text = ''
      if [[ $EUID -ne 0 || $# -ne 0 ]]; then
        echo "Usage: sudo backup-service-bookorbit" >&2
        exit 2
      fi
      exec 9>/run/bookorbit-backup/lock
      flock --nonblock 9 || { echo "BookOrbit backup already running" >&2; exit 1; }
      systemctl is-active --quiet podman-${databaseContainer}.service
      work_dir="$(mktemp --directory ${backupDir}/.incomplete.XXXXXX)"
      app_was_active=false
      cleanup() {
        rm -rf -- "$work_dir"
        if [[ "$app_was_active" == true ]]; then
          systemctl start podman-${appContainer}.service
        fi
      }
      trap cleanup EXIT
      if systemctl is-active --quiet podman-${appContainer}.service; then
        app_was_active=true
        systemctl stop podman-${appContainer}.service
      fi
      # Stop the sole application writer so the database and files agree.
      podman exec ${databaseContainer} pg_dump --username=bookorbit \
        --dbname=bookorbit --format=custom >"$work_dir/database.dump"
      tar --create --zstd --file "$work_dir/files.tar.zst" \
        --directory ${stateRoot} data --directory /srv/media books
      jq --null-input --arg created_at "$(date --utc --iso-8601=seconds)" \
        --arg app_image ${lib.escapeShellArg appImage} \
        --arg database_image ${lib.escapeShellArg databaseImage} \
        '{service: "bookorbit", version: "3.6.0", created_at: $created_at,
          app_image: $app_image, database_image: $database_image}' >"$work_dir/metadata.json"
      (cd "$work_dir"; sha256sum database.dump files.tar.zst metadata.json >SHA256SUMS)
      validate-service-bookorbit-backup "$work_dir"
      if [[ "$app_was_active" == true ]]; then
        systemctl start podman-${appContainer}.service
        systemctl is-active --quiet podman-${appContainer}.service
        app_was_active=false
      fi
      generation=${backupDir}/bookorbit-"$(date --utc +%Y%m%dT%H%M%S%NZ)"
      mv -- "$work_dir" "$generation"
      trap - EXIT
      # Keep the last week's coherent generations; publish before pruning.
      find ${backupDir} -mindepth 1 -maxdepth 1 -type d \
        -name 'bookorbit-*' -mtime +7 -exec rm -rf -- {} +
      echo "Created BookOrbit backup: $generation"
    '';
  };
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable && config.homelab.reverseProxy.enableDnsChallenge;
      message = "BookOrbit requires the private HTTPS reverse proxy";
    }
  ];

  users.groups.bookorbit = { inherit gid; };
  users.users = {
    bookorbit = {
      isSystemUser = true;
      inherit uid;
      group = "bookorbit";
      home = dataDir;
    };
    spenser-admin.extraGroups = [ "bookorbit" ];
  };

  virtualisation = {
    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    oci-containers = {
      backend = "podman";
      containers = {
        ${databaseContainer} = {
          image = databaseImage;
          environment = {
            POSTGRES_USER = "bookorbit";
            POSTGRES_DB = "bookorbit";
            PGDATA = "/var/lib/postgresql/data/pgdata";
          };
          environmentFiles = [ config.sops.templates."bookorbit-database.env".path ];
          volumes = [ "${databaseDir}:/var/lib/postgresql/data" ];
          extraOptions = [ "--network=${networkName}" ];
        };
        ${appContainer} = {
          image = appImage;
          user = "${toString uid}:${toString gid}";
          environment = {
            NODE_ENV = "production";
            PORT = "3000";
            HOST = "0.0.0.0";
            APP_URL = "https://${hostName}";
            CLIENT_URL = "https://${hostName}";
            TZ = "America/New_York";
            POSTGRES_HOST = databaseContainer;
            POSTGRES_PORT = "5432";
            POSTGRES_USER = "bookorbit";
            POSTGRES_DB = "bookorbit";
            PUID = toString uid;
            PGID = toString gid;
            BOOKORBIT_FIX_PERMISSIONS = "false";
            LIBRARY_BROWSE_ROOT = "/books";
            NODE_MAX_OLD_SPACE_SIZE = "2048";
          };
          environmentFiles = [ config.sops.templates."bookorbit.env".path ];
          volumes = [
            "${dataDir}:/data"
            # Initial deployment only: no import or source-file mutations.
            "${booksDir}:/books:ro"
          ];
          ports = [ "127.0.0.1:8094:3000" ];
          dependsOn = [ databaseContainer ];
          extraOptions = [
            "--network=${networkName}"
            "--read-only"
            "--tmpfs=/tmp:rw,nosuid,nodev,mode=1777"
            "--cap-drop=ALL"
            "--security-opt=no-new-privileges"
          ];
        };
      };
    };
  };

  services.caddy.virtualHosts.${hostName}.extraConfig = ''
    import private_tls
    reverse_proxy 127.0.0.1:8094
  '';

  sops = {
    secrets =
      lib.genAttrs
        [
          "bookorbit/database_password"
          "bookorbit/jwt_secret"
          "bookorbit/podcast_encryption_key"
          "bookorbit/setup_bootstrap_token"
        ]
        (_: {
          sopsFile = ../../secrets/homeserver.yaml;
        });
    templates = {
      "bookorbit-database.env" = {
        mode = "0400";
        restartUnits = [
          "podman-${databaseContainer}.service"
          "podman-${appContainer}.service"
        ];
        content = ''
          POSTGRES_PASSWORD=${config.sops.placeholder."bookorbit/database_password"}
        '';
      };
      "bookorbit.env" = {
        mode = "0400";
        restartUnits = [ "podman-${appContainer}.service" ];
        # Independently generated hex secrets are safe in Podman's env-file syntax.
        content = ''
          POSTGRES_PASSWORD=${config.sops.placeholder."bookorbit/database_password"}
          JWT_SECRET=${config.sops.placeholder."bookorbit/jwt_secret"}
          PODCAST_ENCRYPTION_KEY=${config.sops.placeholder."bookorbit/podcast_encryption_key"}
          SETUP_BOOTSTRAP_TOKEN=${config.sops.placeholder."bookorbit/setup_bootstrap_token"}
        '';
      };
    };
  };

  systemd = {
    tmpfiles.rules = [
      "d ${stateRoot} 0750 root root - -"
      "d ${dataDir} 0750 bookorbit bookorbit - -"
      "d ${booksDir} 2770 root bookorbit - -"
      # The upstream PostgreSQL image initializes/chowns its own PGDATA child.
      "d ${databaseDir} 0700 root root - -"
      "d ${backupDir} 0750 root homelab-backup - -"
    ];
    services = {
      bookorbit-network = {
        description = "Create the private BookOrbit container network";
        wantedBy = [ "multi-user.target" ];
        before = [
          "podman-${databaseContainer}.service"
          "podman-${appContainer}.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "create-bookorbit-network" ''
            ${pkgs.podman}/bin/podman network exists ${networkName} || \
              ${pkgs.podman}/bin/podman network create ${networkName}
          '';
        };
      };
      "podman-${databaseContainer}" = {
        requires = [ "bookorbit-network.service" ];
        after = [ "bookorbit-network.service" ];
        unitConfig.RequiresMountsFor = [ databaseDir ];
        serviceConfig.Restart = lib.mkForce "on-failure";
      };
      "podman-${appContainer}" = {
        requires = [ "bookorbit-network.service" ];
        after = [ "bookorbit-network.service" ];
        unitConfig.RequiresMountsFor = [
          dataDir
          booksDir
        ];
        serviceConfig = {
          Restart = lib.mkForce "on-failure";
          ExecStartPre = [ waitForDatabase ];
          TimeoutStartSec = lib.mkForce "5min";
        };
      };
      bookorbit-backup = {
        description = "Create and validate a coherent BookOrbit backup generation";
        requires = [ "podman-${databaseContainer}.service" ];
        after = [ "podman-${databaseContainer}.service" ];
        unitConfig.RequiresMountsFor = [
          dataDir
          booksDir
          backupDir
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe createBackup;
          RuntimeDirectory = "bookorbit-backup";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          TimeoutStartSec = "30min";
        };
      };
    };
  };
  environment.systemPackages = [ validateBackup ];
}
