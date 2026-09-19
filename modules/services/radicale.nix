{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateRoot = "/srv/radicale";
  storage = "${stateRoot}/collections";
  backupDir = "/srv/backups/services/radicale";
  hostName = "calendar.${config.homelab.reverseProxy.baseDomain}";
  backupRadicale = pkgs.writeShellApplication {
    name = "backup-service-radicale";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnutar
      gzip
      util-linux
    ];
    text = ''
      if [[ $EUID -ne 0 || $# -ne 0 ]]; then
        echo "Usage: sudo backup-service-radicale" >&2
        exit 2
      fi
      # Do not create a root-owned lock before the service has initialized.
      test -f ${storage}/.Radicale.lock
      exec 9<${storage}/.Radicale.lock
      flock --exclusive --timeout 120 9
      archive=${backupDir}/radicale-state-"$(date --utc +%Y%m%dT%H%M%S%NZ)".tar.gz
      temporary_archive="$archive.incomplete"
      trap 'rm -f -- "$temporary_archive"' EXIT
      tar --create --gzip --file "$temporary_archive" \
        --exclude='.Radicale.cache' --exclude='.Radicale.tmp-*' \
        --directory ${storage} collection-root
      flock --unlock 9
      tar --list --gzip --file "$temporary_archive" >/dev/null
      mv -- "$temporary_archive" "$archive"
      find ${backupDir} -maxdepth 1 -type f \
        -name 'radicale-state-*.tar.gz' -mtime +7 -delete
      echo "Created Radicale backup: $archive"
    '';
  };
in
{
  assertions = [
    {
      assertion = config.homelab.reverseProxy.enable && config.homelab.reverseProxy.enableDnsChallenge;
      message = "Radicale requires the private HTTPS reverse proxy";
    }
  ];

  services.radicale = {
    enable = true;
    settings = {
      server.hosts = [ "127.0.0.1:5232" ];
      auth = {
        type = "htpasswd";
        htpasswd_filename = "/run/radicale/users";
        htpasswd_encryption = "bcrypt";
      };
      rights.type = "owner_only";
      storage.filesystem_folder = storage;
    };
  };
  services.caddy.virtualHosts.${hostName}.extraConfig = ''
    import private_tls
    redir /.well-known/caldav / 301
    reverse_proxy 127.0.0.1:5232
  '';

  sops.secrets."radicale/household_password" = {
    sopsFile = ../../secrets/radicale.yaml;
    restartUnits = [ "radicale.service" ];
  };

  systemd.tmpfiles.rules = [
    "d ${stateRoot} 0750 radicale radicale - -"
    "d ${storage} 0700 radicale radicale - -"
    "d ${backupDir} 0750 root homelab-backup - -"
  ];
  systemd.services.radicale = {
    unitConfig.RequiresMountsFor = [ stateRoot ];
    serviceConfig = {
      StateDirectory = lib.mkForce [ ];
      WorkingDirectory = lib.mkForce stateRoot;
      RuntimeDirectory = "radicale";
      RuntimeDirectoryMode = "0700";
      LoadCredential = [ "household-password:${config.sops.secrets."radicale/household_password".path}" ];
    };
    preStart = ''
      ${pkgs.apacheHttpd}/bin/htpasswd -niBC 12 household \
        < "$CREDENTIALS_DIRECTORY/household-password" > /run/radicale/users
      chmod 0600 /run/radicale/users
      # Bootstrap only an empty store; never overwrite calendar metadata.
      if [ ! -d ${storage}/collection-root ]; then
        mkdir -p ${storage}/.bootstrap/household/family
        printf '%s\n' '{"tag":"VCALENDAR","D:displayname":"Family","C:supported-calendar-component-set":"VEVENT"}' \
          > ${storage}/.bootstrap/household/family/.Radicale.props
        mv ${storage}/.bootstrap ${storage}/collection-root
      fi
    '';
  };
  systemd.services.radicale-backup = {
    description = "Create a consistent Radicale calendar archive";
    unitConfig.RequiresMountsFor = [
      stateRoot
      backupDir
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe backupRadicale;
      UMask = "0027";
    };
  };
  environment.systemPackages = [ backupRadicale ];
}
