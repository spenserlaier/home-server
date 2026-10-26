{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.trilium;
  package = import ./trilium-package.nix { inherit pkgs; };
  stateDir = "/srv/trilium";
  backupDir = "/srv/backups/services/trilium";
  hostName = "notes.${config.homelab.reverseProxy.baseDomain}";
  port = 8093;
  backupTool = "${pkgs.python3}/bin/python3 ${./trilium-backup.py}";
  createBackup = pkgs.writeShellApplication {
    name = "backup-service-trilium";
    text = ''
      if [[ $EUID -ne 0 || $# -ne 0 ]]; then
        echo "Usage: sudo backup-service-trilium" >&2
        exit 2
      fi
      exec ${backupTool} create ${stateDir} ${backupDir} ${package.version}
    '';
  };
  validateBackup = pkgs.writeShellApplication {
    name = "validate-service-trilium-backup";
    text = ''
      if [[ $# -ne 1 ]]; then
        echo "Usage: validate-service-trilium-backup BACKUP_GENERATION_DIRECTORY" >&2
        exit 2
      fi
      exec ${backupTool} validate "$1"
    '';
  };
in
{
  options.homelab.trilium.enableBackendScripting = lib.mkEnableOption "trusted Trilium backend JavaScript";

  config = {
    assertions = [
      {
        assertion = config.homelab.reverseProxy.enable && config.homelab.reverseProxy.enableDnsChallenge;
        message = "Trilium requires the private HTTPS reverse proxy";
      }
    ];

    services.trilium-server = {
      enable = true;
      inherit package;
      dataDir = stateDir;
      host = "127.0.0.1";
      inherit port;
      instanceName = "Homeserver notes trial";
      noAuthentication = false;
      # Keep the application's local backups as a second recovery layer. Kopia
      # captures its own consistent database; it does not depend on their timer.
      noBackup = false;
    };
    services.caddy.virtualHosts.${hostName}.extraConfig = ''
      import private_tls
      reverse_proxy 127.0.0.1:${toString port}
    '';

    systemd.tmpfiles.rules = [ "d ${backupDir} 0750 root homelab-backup - -" ];
    systemd.services = {
      trilium-server = {
        unitConfig.RequiresMountsFor = [ stateDir ];
        environment = {
          TRILIUM_NETWORK_TRUSTEDREVERSEPROXY = "loopback";
          TRILIUM_SECURITY_BACKEND_SCRIPTING_ENABLED = lib.boolToString cfg.enableBackendScripting;
          TRILIUM_SECURITY_SQL_CONSOLE_ENABLED = "false";
        };
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "5s";
          UMask = "0077";
          NoNewPrivileges = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ stateDir ];
          WorkingDirectory = stateDir;
        };
      };
      trilium-backup = {
        description = "Create and validate a consistent Trilium database generation";
        unitConfig.RequiresMountsFor = [
          stateDir
          backupDir
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe createBackup;
          TimeoutStartSec = "5min";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          # SQLite may need its shared-memory/WAL bookkeeping beside the source.
          ReadWritePaths = [
            stateDir
            backupDir
          ];
        };
      };
    };
    environment.systemPackages = [
      createBackup
      validateBackup
    ];
  };
}
