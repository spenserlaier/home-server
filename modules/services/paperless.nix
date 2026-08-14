{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = config.homelab.reverseProxy.baseDomain;
  hostName = "paperless.${domain}";
  paperlessRoot = "/srv/paperless";
  exportDir = "/srv/backups/services/paperless";
  postgresDir = "/srv/postgresql/${config.services.postgresql.package.psqlSchema}";

  validateExport = pkgs.writeShellApplication {
    name = "validate-service-paperless-backup";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      jq
    ];
    text = ''
      if [[ $# -ne 1 ]]; then
        echo "Usage: validate-service-paperless-backup EXPORT_DIRECTORY" >&2
        exit 2
      fi

      export_dir="$(realpath -e -- "$1")"
      [[ -d "$export_dir" && ! -L "$export_dir" ]] || {
        echo "Paperless export must be a non-symlink directory" >&2
        exit 1
      }
      [[ -f "$export_dir/manifest.json" && ! -L "$export_dir/manifest.json" ]] || {
        echo "Paperless export is missing a regular manifest.json" >&2
        exit 1
      }

      jq --exit-status '
        type == "array" and
        length > 0 and
        all(.[];
          type == "object" and
          (.model | type == "string" and length > 0) and
          has("pk") and
          (.fields | type == "object")
        )
      ' "$export_dir/manifest.json" >/dev/null
      find "$export_dir" -xdev -type l -print -quit | grep -q . && {
        echo "Paperless export unexpectedly contains a symbolic link" >&2
        exit 1
      }

      echo "Validated Paperless export: $export_dir"
    '';
  };
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable;
      message = "Paperless requires the homelab reverse proxy";
    }
    {
      assertion = config.homelab.reverseProxy.enableDnsChallenge;
      message = "Paperless's private HTTPS host requires DNS-01 support";
    }
  ];

  services = {
    paperless = {
      enable = true;
      address = "127.0.0.1";
      port = 28981;
      domain = hostName;
      dataDir = "${paperlessRoot}/data";
      mediaDir = "${paperlessRoot}/media";
      consumptionDir = "${paperlessRoot}/consume";
      consumptionDirIsPublic = false;
      passwordFile = config.sops.secrets."paperless/admin_password".path;
      environmentFile = config.sops.templates."paperless.env".path;
      database.createLocally = true;
      exporter = {
        enable = true;
        directory = exportDir;
        # Kopia starts the exporter as an application-consistency prerequisite.
        onCalendar = null;
      };
      settings = {
        PAPERLESS_ADMIN_USER = "admin";
        PAPERLESS_ALLOWED_HOSTS = hostName;
      };
    };

    # This is shared database infrastructure for Paperless and later services,
    # not disposable operating-system state beneath /var/lib.
    postgresql.dataDir = postgresDir;

    caddy.virtualHosts.${hostName}.extraConfig = ''
      import private_tls
      reverse_proxy 127.0.0.1:${toString config.services.paperless.port}
    '';
  };

  sops = {
    secrets = {
      "paperless/admin_password" = {
        sopsFile = ../../secrets/homeserver.yaml;
        owner = "paperless";
        group = "paperless";
        mode = "0400";
      };
      "paperless/secret_key" = {
        sopsFile = ../../secrets/homeserver.yaml;
      };
    };
    templates."paperless.env" = {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
      content = ''
        PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless/secret_key"}
      '';
    };
  };

  users.users.paperless.extraGroups = [ "homelab-backup" ];

  systemd = {
    tmpfiles.settings."00-homelab-paperless" = {
      ${paperlessRoot}.d = {
        mode = "0750";
        user = "paperless";
        group = "paperless";
      };
      "${paperlessRoot}/data".d = {
        mode = "0750";
        user = "paperless";
        group = "paperless";
      };
      "${paperlessRoot}/media".d = {
        mode = "0750";
        user = "paperless";
        group = "paperless";
      };
      "${paperlessRoot}/consume".d = {
        mode = "0750";
        user = "paperless";
        group = "paperless";
      };
      "/srv/postgresql".d = {
        mode = "0750";
        user = "postgres";
        group = "postgres";
      };
      ${postgresDir}.d = {
        mode = "0700";
        user = "postgres";
        group = "postgres";
      };
      ${exportDir}.d = {
        mode = "0700";
        user = "paperless";
        group = "paperless";
      };
    };

    services.paperless-exporter.serviceConfig.ExecStartPost = "${lib.getExe validateExport} ${lib.escapeShellArg exportDir}";
  };

  environment.systemPackages = [ validateExport ];
}
