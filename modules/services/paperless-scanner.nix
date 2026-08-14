{
  config,
  lib,
  pkgs,
  ...
}:
let
  scannerAddress = "192.168.4.38";
  scannerUser = "paperless-scanner";
  scannerRoot = "/srv/paperless-scanner";
  stagingDir = "${scannerRoot}/inbox";
  consumptionDir = config.services.paperless.consumptionDir;

  scannerPublicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDWq9TZXr5x+/0ufI/tFWO8yBGL0LdsETbxReaty7nhPZsNMl5X7RQGx5SaEVUSnjpJRaeMF5mMQaPp3W0wlygFW6S+Y0fqf51fPQqehxWzcpiiD/mw/ljrw4fdaTPpnN/B7CbiMLPwN5z9g6FTTWG5pfIbpRSJIYhqede/8Bv+LDaip3sr/WQwoUWBTqe+XHS8EHzj0wUY84NZ79BP/KkXrVHl0yvZp4hQhodu1HPj52KtQSy51/E7IpJEx1S4Y/h8Uj+8AnOonNWquVYodEe78nXdO+osJqDItxVrcdx2Q4ZSfZHku+FqDMsIL9BdfIfZK0mvcblwiXgTRfU252Np root@BRN000EC69C98ED";

  handoffScans = pkgs.writeShellApplication {
    name = "handoff-paperless-scans";
    runtimeInputs = with pkgs; [
      coreutils
      psmisc
    ];
    text = ''
      shopt -s nullglob

      now="$(date +%s)"
      for source in ${lib.escapeShellArg stagingDir}/*; do
        [[ -f "$source" && ! -L "$source" ]] || {
          echo "Refusing unexpected scanner inbox entry: $source" >&2
          exit 1
        }
        [[ "''${source,,}" == *.pdf ]] || {
          echo "Refusing non-PDF scanner upload: $source" >&2
          exit 1
        }
        [[ "$(stat --format=%U -- "$source")" == ${lib.escapeShellArg scannerUser} ]] || {
          echo "Refusing scanner upload with unexpected owner: $source" >&2
          exit 1
        }

        # An SFTP upload is not ready merely because its directory entry exists.
        # Require both a closed descriptor and a quiet interval before handoff.
        if fuser --silent -- "$source"; then
          continue
        fi
        modified="$(stat --format=%Y -- "$source")"
        if (( now - modified < 30 )); then
          continue
        fi

        target=${lib.escapeShellArg consumptionDir}/"$(basename -- "$source")"
        [[ ! -e "$target" && ! -L "$target" ]] || {
          echo "Refusing to replace an existing Paperless consumption file: $target" >&2
          exit 1
        }

        chown paperless:paperless -- "$source"
        chmod 0600 -- "$source"
        # Both directories reside on the /srv subvolume, so this is an atomic rename.
        mv --no-target-directory -- "$source" "$target"
        echo "Handed scanner upload to Paperless: $(basename -- "$target")"
      done
    '';
  };
in
{
  assertions = [
    {
      assertion = config.services.paperless.enable;
      message = "The Paperless scanner integration requires Paperless";
    }
  ];

  users = {
    groups.${scannerUser} = { };
    users.${scannerUser} = {
      isSystemUser = true;
      group = scannerUser;
      home = "/inbox";
      shell = "${pkgs.shadow}/bin/nologin";
      openssh.authorizedKeys.keys = [
        ''from="${scannerAddress}",restrict ${scannerPublicKey}''
      ];
    };
  };

  services.openssh.extraConfig = ''
    Match User ${scannerUser}
      AuthenticationMethods publickey
      PasswordAuthentication no
      ChrootDirectory ${scannerRoot}
      ForceCommand internal-sftp -d /inbox
      DisableForwarding yes
      PermitTTY no
      X11Forwarding no
  '';

  systemd = {
    tmpfiles.settings."00-paperless-scanner" = {
      ${scannerRoot}.d = {
        mode = "0755";
        user = "root";
        group = "root";
      };
      ${stagingDir}.d = {
        mode = "0700";
        user = scannerUser;
        group = scannerUser;
      };
    };

    services.paperless-scanner-handoff = {
      description = "Atomically hand completed scanner uploads to Paperless";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        UMask = "0077";
        ExecStart = lib.getExe handoffScans;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          stagingDir
          consumptionDir
        ];
      };
    };

    timers.paperless-scanner-handoff = {
      description = "Check for completed Paperless scanner uploads";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "30s";
        Unit = "paperless-scanner-handoff.service";
      };
    };
  };

  environment.systemPackages = [ handoffScans ];
}
