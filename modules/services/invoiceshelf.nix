{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = config.homelab.reverseProxy.baseDomain;
  hostName = "invoices.${domain}";
  serviceRoot = "/srv/invoiceshelf";
  storageDir = "${serviceRoot}/storage";
  modulesDir = "${serviceRoot}/modules";
  databaseDir = "${serviceRoot}/database";
  exportDir = "/srv/backups/services/invoiceshelf";
  networkName = "invoiceshelf";
  appContainer = "invoiceshelf";
  databaseContainer = "invoiceshelf-database";
  appImage = "docker.io/invoiceshelf/invoiceshelf:2.4.2@sha256:cc6e097fcf4d5e5d0480b68aba7fac4bb86c2e46d80c0c5c17e697aee6356cd8";
  databaseImage = "docker.io/library/mariadb:10.11.14@sha256:3a7d3cbc8b6fddf66433d80dc124c1e4e75a73ebab9c6e137529cc270bdadfc0";

  validateBackup = pkgs.writeShellApplication {
    name = "validate-service-invoiceshelf-backup";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      gzip
      jq
      gnutar
      zstd
    ];
    text = ''
      if [[ $# -ne 1 ]]; then
        echo "Usage: validate-service-invoiceshelf-backup EXPORT_DIRECTORY" >&2
        exit 2
      fi

      export_dir="$(realpath -e -- "$1")"
      [[ -d "$export_dir" && ! -L "$export_dir" ]] || {
        echo "InvoiceShelf backup must be a non-symlink directory" >&2
        exit 1
      }

      for artifact in database.sql.gz storage.tar.zst metadata.json; do
        [[ -s "$export_dir/$artifact" && ! -L "$export_dir/$artifact" ]] || {
          echo "InvoiceShelf backup is missing regular artifact: $artifact" >&2
          exit 1
        }
      done

      gzip --test "$export_dir/database.sql.gz"
      gzip --decompress --stdout "$export_dir/database.sql.gz" \
        | grep --fixed-strings --max-count=1 'MariaDB dump' >/dev/null

      archive_listing="$(mktemp)"
      trap 'rm -f "$archive_listing"' EXIT
      tar --zstd --list --file "$export_dir/storage.tar.zst" >"$archive_listing"
      grep --extended-regexp '^storage(/|$)' "$archive_listing" >/dev/null
      grep --extended-regexp '^modules(/|$)' "$archive_listing" >/dev/null
      grep --extended-regexp '(^/|(^|/)\.\.(/|$))' "$archive_listing" && {
        echo "InvoiceShelf storage archive contains an unsafe path" >&2
        exit 1
      }

      jq --exit-status \
        --arg app_image ${lib.escapeShellArg appImage} \
        --arg database_image ${lib.escapeShellArg databaseImage} '
          .service == "invoiceshelf" and
          .version == "2.4.2" and
          .app_image == $app_image and
          .database_image == $database_image and
          (.created_at | type == "string" and length > 0)
        ' "$export_dir/metadata.json" >/dev/null

      echo "Validated InvoiceShelf backup: $export_dir"
    '';
  };

  createBackup = pkgs.writeShellApplication {
    name = "backup-invoiceshelf";
    runtimeInputs = with pkgs; [
      coreutils
      gzip
      jq
      podman
      systemd
      gnutar
      util-linux
      validateBackup
      zstd
    ];
    text = ''
      export_dir=${lib.escapeShellArg exportDir}
      parent_dir="$(dirname "$export_dir")"
      work_dir="$(mktemp --directory --tmpdir="$parent_dir" .invoiceshelf-backup.XXXXXX)"
      cleanup() {
        rm -rf -- "$work_dir"
      }
      restart_app() {
        systemctl start podman-${appContainer}.service
      }
      trap cleanup EXIT

      exec 9>/run/invoiceshelf-backup/lock
      flock --nonblock 9 || {
        echo "An InvoiceShelf backup is already running" >&2
        exit 1
      }

      systemctl is-active --quiet podman-${databaseContainer}.service
      systemctl stop podman-${appContainer}.service
      trap 'restart_app; cleanup' EXIT

      podman exec ${databaseContainer} sh -c \
        'exec mariadb-dump --user="$MARIADB_USER" --password="$MARIADB_PASSWORD" --single-transaction --quick --skip-lock-tables --databases "$MARIADB_DATABASE"' \
        | gzip --best >"$work_dir/database.sql.gz"

      tar --create --zstd --file "$work_dir/storage.tar.zst" \
        --directory ${lib.escapeShellArg serviceRoot} storage modules

      jq --null-input \
        --arg created_at "$(date --utc --iso-8601=seconds)" \
        --arg app_image ${lib.escapeShellArg appImage} \
        --arg database_image ${lib.escapeShellArg databaseImage} \
        '{
          service: "invoiceshelf",
          version: "2.4.2",
          created_at: $created_at,
          database: "MariaDB 10.11.14",
          app_image: $app_image,
          database_image: $database_image
        }' >"$work_dir/metadata.json"

      chmod 0600 "$work_dir"/*
      validate-service-invoiceshelf-backup "$work_dir"

      restart_app
      trap cleanup EXIT
      systemctl is-active --quiet podman-${appContainer}.service

      old_dir="${exportDir}.old"
      rm -rf -- "$old_dir"
      if [[ -e "$export_dir" ]]; then
        mv -- "$export_dir" "$old_dir"
      fi
      mv -- "$work_dir" "$export_dir"
      rm -rf -- "$old_dir"
      trap - EXIT

      echo "Created validated InvoiceShelf backup: $export_dir"
    '';
  };
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable;
      message = "InvoiceShelf requires the homelab reverse proxy";
    }
    {
      assertion = config.homelab.reverseProxy.enableDnsChallenge;
      message = "InvoiceShelf's private HTTPS host requires DNS-01 support";
    }
  ];

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
            MARIADB_DATABASE = "invoiceshelf";
            MARIADB_USER = "invoiceshelf";
          };
          environmentFiles = [ config.sops.templates."invoiceshelf-database.env".path ];
          volumes = [ "${databaseDir}:/var/lib/mysql" ];
          extraOptions = [ "--network=${networkName}" ];
        };

        ${appContainer} = {
          image = appImage;
          environment = {
            APP_NAME = "InvoiceShelf";
            APP_ENV = "production";
            APP_DEBUG = "false";
            APP_URL = "https://${hostName}";
            SESSION_DOMAIN = hostName;
            SANCTUM_STATEFUL_DOMAINS = hostName;
            DB_CONNECTION = "mariadb";
            DB_HOST = databaseContainer;
            DB_PORT = "3306";
            DB_DATABASE = "invoiceshelf";
            DB_USERNAME = "invoiceshelf";
            CACHE_STORE = "file";
            SESSION_DRIVER = "file";
            SESSION_LIFETIME = "240";
            AUTORUN_ENABLED = "true";
            AUTORUN_LARAVEL_MIGRATION = "false";
            AUTORUN_LARAVEL_OPTIMIZE = "false";
            PHP_OPCACHE_ENABLE = "1";
            TIMEZONE = "America/New_York";
          };
          environmentFiles = [ config.sops.templates."invoiceshelf.env".path ];
          volumes = [
            "${storageDir}:/var/www/html/storage"
            "${modulesDir}:/var/www/html/Modules"
          ];
          ports = [ "127.0.0.1:8091:8080" ];
          extraOptions = [ "--network=${networkName}" ];
          dependsOn = [ databaseContainer ];
        };
      };
    };
  };

  services.caddy.virtualHosts.${hostName}.extraConfig = ''
    import private_tls
    reverse_proxy 127.0.0.1:8091
  '';

  sops = {
    secrets = {
      "invoiceshelf/app_key" = {
        sopsFile = ../../secrets/homeserver.yaml;
      };
      "invoiceshelf/database_password" = {
        sopsFile = ../../secrets/homeserver.yaml;
      };
      "invoiceshelf/database_root_password" = {
        sopsFile = ../../secrets/homeserver.yaml;
      };
    };
    templates = {
      "invoiceshelf.env" = {
        mode = "0400";
        content = ''
          # Podman's env-file parser preserves shell quote characters. Laravel
          # keys use an env-file-safe base64 alphabet, so render this value raw.
          APP_KEY=${config.sops.placeholder."invoiceshelf/app_key"}
          DB_PASSWORD=${lib.escapeShellArg config.sops.placeholder."invoiceshelf/database_password"}
        '';
      };
      "invoiceshelf-database.env" = {
        mode = "0400";
        content = ''
          MARIADB_PASSWORD=${lib.escapeShellArg config.sops.placeholder."invoiceshelf/database_password"}
          MARIADB_ROOT_PASSWORD=${lib.escapeShellArg config.sops.placeholder."invoiceshelf/database_root_password"}
        '';
      };
    };
  };

  systemd = {
    tmpfiles.rules = [
      "d ${serviceRoot} 0750 root root - -"
      # The upstream image runs as www-data with uid/gid 82 and refuses
      # writable bind mounts owned by another identity.
      "d ${storageDir} 0750 82 82 - -"
      "d ${storageDir}/app 0750 82 82 - -"
      "d ${storageDir}/app/templates 0750 82 82 - -"
      "d ${storageDir}/app/templates/pdf 0750 82 82 - -"
      "d ${modulesDir} 0750 82 82 - -"
      "d ${databaseDir} 0700 root root - -"
      "d ${exportDir} 0700 root root - -"
    ];

    services = {
      invoiceshelf-network = {
        description = "Create the private InvoiceShelf container network";
        wantedBy = [ "multi-user.target" ];
        before = [
          "podman-${databaseContainer}.service"
          "podman-${appContainer}.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "create-invoiceshelf-network" ''
            ${pkgs.podman}/bin/podman network exists ${networkName} || \
              ${pkgs.podman}/bin/podman network create ${networkName}
          '';
        };
      };

      "podman-${databaseContainer}" = {
        requires = [ "invoiceshelf-network.service" ];
        after = [ "invoiceshelf-network.service" ];
        serviceConfig.Restart = lib.mkForce "on-failure";
      };

      "podman-${appContainer}" = {
        requires = [ "invoiceshelf-network.service" ];
        after = [ "invoiceshelf-network.service" ];
        serviceConfig.Restart = lib.mkForce "on-failure";
      };

      invoiceshelf-backup = {
        description = "Create and validate an InvoiceShelf backup";
        requires = [ "podman-${databaseContainer}.service" ];
        after = [ "podman-${databaseContainer}.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe createBackup;
          RuntimeDirectory = "invoiceshelf-backup";
          RuntimeDirectoryMode = "0700";
        };
      };
    };
  };

  environment.systemPackages = [ validateBackup ];
}
