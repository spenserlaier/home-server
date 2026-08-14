{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.backup.kopia;
  repositoryConfig = ''"$RUNTIME_DIRECTORY/repository.config"'';
  restoreRoot = "/srv/restore-tests";

  credentialEnvironment = ''
    KOPIA_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/repository-password")"
    AWS_ACCESS_KEY_ID="$(<"$CREDENTIALS_DIRECTORY/access-key-id")"
    AWS_SECRET_ACCESS_KEY="$(<"$CREDENTIALS_DIRECTORY/secret-access-key")"
    export KOPIA_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  '';

  repositoryArguments = ''
    --bucket=${lib.escapeShellArg cfg.bucket} \
    --endpoint=${lib.escapeShellArg cfg.endpoint} \
    --region=${lib.escapeShellArg cfg.region}
  '';

  repositoryCreationArguments = ''
    --bucket=${lib.escapeShellArg cfg.bucket} \
    --endpoint=${lib.escapeShellArg cfg.endpoint} \
    --region=${lib.escapeShellArg cfg.region} \
    --retention-mode=${lib.escapeShellArg cfg.objectLock.mode} \
    --retention-period=${lib.escapeShellArg cfg.objectLock.period}
  '';

  readOnlyRepositoryArguments = ''
    --bucket=${lib.escapeShellArg cfg.bucket} \
    --endpoint=${lib.escapeShellArg cfg.endpoint} \
    --region=${lib.escapeShellArg cfg.region} \
    --readonly
  '';

  administrativeCredentialEnvironment = ''
    KOPIA_PASSWORD="$(<${lib.escapeShellArg config.sops.secrets."kopia/repository_password".path})"
    AWS_ACCESS_KEY_ID="$(<${lib.escapeShellArg config.sops.secrets."kopia/b2_key_id".path})"
    AWS_SECRET_ACCESS_KEY="$(<${
      lib.escapeShellArg config.sops.secrets."kopia/b2_application_key".path
    })"
    export KOPIA_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  '';

  connectReadOnlyRepository = ''
    working_dir="$(mktemp --directory --tmpdir=/run kopia-readonly.XXXXXX)"
    trap 'rm -r -- "$working_dir"' EXIT
    config_file="$working_dir/repository.config"
    cache_dir="$working_dir/cache"
    KOPIA_LOG_DIR="$working_dir/logs"
    KOPIA_CHECK_FOR_UPDATES=false
    export KOPIA_LOG_DIR KOPIA_CHECK_FOR_UPDATES

    ${administrativeCredentialEnvironment}
    kopia --config-file="$config_file" repository connect s3 \
      --cache-directory="$cache_dir" \
      ${readOnlyRepositoryArguments}
  '';

  listSnapshots = pkgs.writeShellApplication {
    name = "list-kopia-snapshots";
    runtimeInputs = with pkgs; [
      coreutils
      kopia
    ];
    text = ''
      if [[ $EUID -ne 0 ]]; then
        echo "This command must run as root" >&2
        exit 1
      fi
      if [[ $# -ne 0 ]]; then
        echo "Usage: list-kopia-snapshots" >&2
        exit 2
      fi

      ${connectReadOnlyRepository}
      kopia --config-file="$config_file" snapshot list --all
    '';
  };

  restoreSnapshot = pkgs.writeShellApplication {
    name = "restore-kopia-snapshot";
    runtimeInputs = with pkgs; [
      coreutils
      kopia
    ];
    text = ''
      if [[ $EUID -ne 0 ]]; then
        echo "This command must run as root" >&2
        exit 1
      fi
      if [[ $# -ne 2 ]]; then
        echo "Usage: restore-kopia-snapshot SNAPSHOT_ROOT_ID TARGET_DIRECTORY" >&2
        exit 2
      fi

      snapshot_id="$1"
      [[ "$snapshot_id" =~ ^k[[:xdigit:]]+$ ]] || {
        echo "Snapshot root ID must begin with k and contain only hexadecimal characters" >&2
        exit 1
      }

      restore_root="$(realpath -e -- ${lib.escapeShellArg restoreRoot})"
      target="$(realpath -m -- "$2")"
      case "$target" in
        "$restore_root"/*) ;;
        *)
          echo "Target must be a new path beneath $restore_root" >&2
          exit 1
          ;;
      esac
      [[ ! -e "$target" && ! -L "$target" ]] || {
        echo "Restore target already exists: $target" >&2
        exit 1
      }
      [[ -d "$(dirname -- "$target")" ]] || {
        echo "Restore target parent does not exist" >&2
        exit 1
      }

      ${connectReadOnlyRepository}
      kopia --config-file="$config_file" snapshot restore \
        --write-files-atomically \
        "$snapshot_id" "$target"

      echo "Restored Kopia snapshot $snapshot_id to $target"
    '';
  };

  initializeRepository = pkgs.writeShellApplication {
    name = "initialize-kopia-repository";
    runtimeInputs = [ pkgs.kopia ];
    text = ''
      ${credentialEnvironment}

      kopia --config-file=${repositoryConfig} repository create s3 \
        ${repositoryCreationArguments}

      kopia --config-file=${repositoryConfig} policy set ${lib.escapeShellArg cfg.source} \
        --manual \
        --keep-latest=${toString cfg.retention.latest} \
        --keep-daily=${toString cfg.retention.daily} \
        --keep-weekly=${toString cfg.retention.weekly} \
        --keep-monthly=${toString cfg.retention.monthly} \
        --keep-annual=${toString cfg.retention.annual}

      kopia --config-file=${repositoryConfig} repository status
    '';
  };

  connectRepository = ''
    ${credentialEnvironment}
    kopia --config-file=${repositoryConfig} repository connect s3 \
      ${repositoryArguments}
  '';

  createSnapshot = pkgs.writeShellApplication {
    name = "backup-with-kopia";
    runtimeInputs = [ pkgs.kopia ];
    text = ''
      ${connectRepository}

      # Reassert the policy so retention remains declarative if it is changed
      # from another Kopia client.
      kopia --config-file=${repositoryConfig} policy set ${lib.escapeShellArg cfg.source} \
        --manual \
        --keep-latest=${toString cfg.retention.latest} \
        --keep-daily=${toString cfg.retention.daily} \
        --keep-weekly=${toString cfg.retention.weekly} \
        --keep-monthly=${toString cfg.retention.monthly} \
        --keep-annual=${toString cfg.retention.annual}

      kopia --config-file=${repositoryConfig} snapshot create ${lib.escapeShellArg cfg.source}
      kopia --config-file=${repositoryConfig} snapshot verify
    '';
  };

  verifyRepository = pkgs.writeShellApplication {
    name = "verify-kopia-repository";
    runtimeInputs = [ pkgs.kopia ];
    text = ''
      ${connectRepository}
      kopia --config-file=${repositoryConfig} snapshot verify \
        --verify-files-percent=${toString cfg.verifyFilesPercent}
    '';
  };

  credentials = [
    "repository-password:${config.sops.secrets."kopia/repository_password".path}"
    "access-key-id:${config.sops.secrets."kopia/b2_key_id".path}"
    "secret-access-key:${config.sops.secrets."kopia/b2_application_key".path}"
  ];

  commonServiceConfig = {
    Type = "oneshot";
    User = "root";
    Group = "root";
    UMask = "0077";
    LoadCredential = credentials;
    CacheDirectory = "kopia";
    CacheDirectoryMode = "0700";
    Environment = [
      "KOPIA_CACHE_DIRECTORY=/var/cache/kopia"
      "KOPIA_LOG_DIR=/var/cache/kopia/logs"
      "KOPIA_CHECK_FOR_UPDATES=false"
    ];
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectHome = true;
    ProtectSystem = "strict";
  };
in
{
  options.homelab.backup.kopia = {
    enable = lib.mkEnableOption "encrypted off-host backups with Kopia";

    bucket = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "S3-compatible bucket containing the Kopia repository.";
    };
    endpoint = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "S3-compatible storage endpoint without a URL scheme.";
    };
    region = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "S3-compatible storage region.";
    };
    source = lib.mkOption {
      type = lib.types.str;
      default = "/srv/backups";
      description = "Staging tree captured as one Kopia generation.";
    };
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:15:00";
      description = "systemd OnCalendar expression for Kopia snapshots.";
    };
    verificationSchedule = lib.mkOption {
      type = lib.types.str;
      default = "Sun *-*-* 06:00:00";
      description = "systemd OnCalendar expression for sampled content verification.";
    };
    verifyFilesPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 5;
      description = "Percentage of snapshot files downloaded and verified each week.";
    };
    objectLock = {
      mode = lib.mkOption {
        type = lib.types.enum [
          "GOVERNANCE"
          "COMPLIANCE"
        ];
        default = "COMPLIANCE";
        description = "Object Lock mode applied by Kopia to repository blobs.";
      };
      period = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "30d";
        description = "Object Lock duration applied by Kopia to repository blobs.";
      };
    };
    retention = {
      latest = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 10;
      };
      daily = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 7;
      };
      weekly = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 4;
      };
      monthly = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 12;
      };
      annual = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets = {
      "kopia/repository_password" = {
        sopsFile = ../../secrets/homeserver.yaml;
        mode = "0400";
      };
      "kopia/b2_key_id" = {
        sopsFile = ../../secrets/homeserver.yaml;
        mode = "0400";
      };
      "kopia/b2_application_key" = {
        sopsFile = ../../secrets/homeserver.yaml;
        mode = "0400";
      };
    };

    systemd.tmpfiles.rules = [ "d ${restoreRoot} 0700 root root - -" ];

    systemd.services = {
      kopia-repository-init = {
        description = "Initialize the dedicated Kopia repository";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = commonServiceConfig // {
          ExecStart = lib.getExe initializeRepository;
          RuntimeDirectory = "kopia-init";
          RuntimeDirectoryMode = "0700";
        };
      };

      kopia-backup = {
        description = "Create an encrypted off-host backup generation";
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "jellyfin-backup.service"
        ];
        requires = [ "jellyfin-backup.service" ];
        serviceConfig = commonServiceConfig // {
          ExecStart = lib.getExe createSnapshot;
          RuntimeDirectory = "kopia-backup";
          RuntimeDirectoryMode = "0700";
          ReadOnlyPaths = [ cfg.source ];
        };
      };

      kopia-verify = {
        description = "Verify encrypted Kopia snapshot contents";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = commonServiceConfig // {
          ExecStart = lib.getExe verifyRepository;
          RuntimeDirectory = "kopia-verify";
          RuntimeDirectoryMode = "0700";
        };
      };
    };

    systemd.timers = {
      kopia-backup = {
        description = "Daily encrypted off-host backup";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
          Unit = "kopia-backup.service";
        };
      };
      kopia-verify = {
        description = "Weekly sampled Kopia content verification";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.verificationSchedule;
          Persistent = true;
          RandomizedDelaySec = "1h";
          Unit = "kopia-verify.service";
        };
      };
    };

    environment.systemPackages = [
      listSnapshots
      restoreSnapshot
    ];
  };
}
