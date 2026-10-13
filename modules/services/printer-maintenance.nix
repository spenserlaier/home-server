{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.printerMaintenance;
  root = "/srv/printer-maintenance";
  user = "printer-maintenance";
  run = pkgs.writeShellApplication {
    name = "check-printer-maintenance";
    runtimeInputs = [
      pkgs.cups
      pkgs.python3
    ];
    text = ''
      export LC_ALL=C
      exec python3 ${./printer-maintenance.py} \
        --state-directory ${lib.escapeShellArg root} \
        --printer-uri ${lib.escapeShellArg "ipp://${config.homelab.paperlessPrinter.printerAddress}/ipp/print"} \
        --queue Epson_ET_4950 \
        --idle-days ${toString cfg.idleDays} \
        --maximum-days ${toString cfg.maximumDays} "$@"
    '';
  };
in
{
  options.homelab.printerMaintenance = {
    enable = lib.mkEnableOption "inactivity-aware Epson maintenance printing";
    idleDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Days without a successful physical print before a color exercise page is due.";
    };
    maximumDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Maximum days between dedicated color exercise pages, regardless of other prints.";
    };
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 09..18:00:00 America/New_York";
      description = "Daytime checks; missed checks do not accumulate maintenance jobs.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.homelab.paperlessPrinter.enable;
        message = "Printer maintenance requires the configured Epson CUPS queue";
      }
      {
        assertion = cfg.maximumDays >= cfg.idleDays;
        message = "Printer maintenance maximumDays must be at least idleDays";
      }
    ];

    users.groups.${user} = { };
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = root;
    };
    systemd.tmpfiles.rules = [ "d ${root} 0700 ${user} ${user} - -" ];
    # Retain job metadata for ambiguous-submission recovery, without retaining
    # document payloads. The printer's own completion still confirms delivery.
    services.printing.extraConf = ''
      PreserveJobHistory 2592000
      PreserveJobFiles No
    '';
    systemd.services.printer-maintenance = {
      description = "Print a color exercise page only when due";
      after = [
        "cups.service"
        "paperless-printer-configure.service"
        "network-online.target"
      ];
      wants = [
        "cups.service"
        "network-online.target"
      ];
      requires = [ "paperless-printer-configure.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        UMask = "0077";
        ExecStart = lib.getExe run;
        TimeoutStartSec = "4min";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ root ];
      };
    };
    systemd.timers.printer-maintenance = {
      description = "Check Epson print activity during daytime hours";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        # Catching up at boot could print outside the intended daytime window.
        Persistent = false;
      };
    };
    environment.systemPackages = [ run ];
  };
}
