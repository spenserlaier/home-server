{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.backup.kopia;
  hostName = "backups.${config.homelab.reverseProxy.baseDomain}";
  port = 51515;
  restoreDirectory = "/srv/kopia-ui/restores";

  startUI = pkgs.writeShellApplication {
    name = "start-kopia-ui";
    runtimeInputs = [ pkgs.kopia ];
    text = ''
      KOPIA_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/repository-password")"
      AWS_ACCESS_KEY_ID="$(<"$CREDENTIALS_DIRECTORY/access-key-id")"
      AWS_SECRET_ACCESS_KEY="$(<"$CREDENTIALS_DIRECTORY/secret-access-key")"
      KOPIA_SERVER_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/ui-password")"
      export KOPIA_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY KOPIA_SERVER_PASSWORD

      kopia --config-file="$RUNTIME_DIRECTORY/repository.config" repository connect s3 \
        --bucket=${lib.escapeShellArg cfg.bucket} \
        --endpoint=${lib.escapeShellArg cfg.endpoint} \
        --region=${lib.escapeShellArg cfg.region} \
        --readonly

      # HTTP is restricted to loopback; Caddy provides HTTPS and Kopia requires
      # its own login. The existing systemd jobs remain the only writers.
      exec kopia --config-file="$RUNTIME_DIRECTORY/repository.config" server start \
        --address=http://127.0.0.1:${toString port} \
        --insecure \
        --server-username=admin \
        --readonly \
        --no-grpc \
        --no-enable-actions \
        --refresh-interval=5m
    '';
  };
in
{
  options.homelab.backup.kopia.ui.enable =
    lib.mkEnableOption "the private Kopia browse and restore UI";

  config = lib.mkIf cfg.ui.enable {
    assertions = [
      {
        assertion = cfg.enable;
        message = "The Kopia UI requires homelab.backup.kopia.enable";
      }
      {
        assertion = config.homelab.reverseProxy.enable && config.homelab.reverseProxy.enableDnsChallenge;
        message = "The Kopia UI requires the private HTTPS reverse proxy";
      }
    ];

    users.groups.kopia-ui = { };
    users.users.kopia-ui = {
      isSystemUser = true;
      group = "kopia-ui";
      home = "/run/kopia-ui";
    };

    sops.secrets."kopia/ui_password" = {
      sopsFile = ../../secrets/homeserver.yaml;
      mode = "0400";
      restartUnits = [ "kopia-ui.service" ];
    };

    systemd.tmpfiles.rules = [
      "d /srv/kopia-ui 0700 kopia-ui kopia-ui - -"
      "d ${restoreDirectory} 0700 kopia-ui kopia-ui - -"
    ];

    systemd.services.kopia-ui = {
      description = "Private Kopia backup browser";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = {
        HOME = "/run/kopia-ui";
        KOPIA_CACHE_DIRECTORY = "/var/cache/kopia-ui";
        KOPIA_LOG_DIR = "/var/cache/kopia-ui/logs";
        KOPIA_CHECK_FOR_UPDATES = "false";
      };
      serviceConfig = {
        User = "kopia-ui";
        Group = "kopia-ui";
        UMask = "0077";
        LoadCredential = [
          "repository-password:${config.sops.secrets."kopia/repository_password".path}"
          "access-key-id:${config.sops.secrets."kopia/b2_key_id".path}"
          "secret-access-key:${config.sops.secrets."kopia/b2_application_key".path}"
          "ui-password:${config.sops.secrets."kopia/ui_password".path}"
        ];
        ExecStart = lib.getExe startUI;
        WorkingDirectory = restoreDirectory;
        RuntimeDirectory = "kopia-ui";
        RuntimeDirectoryMode = "0700";
        CacheDirectory = "kopia-ui";
        CacheDirectoryMode = "0700";
        ReadWritePaths = [ restoreDirectory ];
        Restart = "on-failure";
        RestartSec = "30s";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    services.caddy.virtualHosts.${hostName}.extraConfig = ''
      import private_tls
      reverse_proxy 127.0.0.1:${toString port}
    '';
  };
}
