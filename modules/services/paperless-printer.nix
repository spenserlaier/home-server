{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.paperlessPrinter;
  serviceUser = "paperless-printer";
  root = "/srv/paperless-printer";
  jobsDir = "${root}/jobs";
  saveSpool = "${root}/ipp-save";
  printSaveSpool = "${root}/ipp-print-save";
  consumptionDir = config.services.paperless.consumptionDir;
  physicalQueue = "Epson_ET_4950";

  enqueue = pkgs.writeShellApplication {
    name = "enqueue-paperless-print";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      qpdf
      util-linux
    ];
    text = ''
      if [[ $# -ne 2 ]]; then
        echo "ERROR: Usage: enqueue-paperless-print MODE PDF" >&2
        exit 1
      fi
      mode="$1"
      source="$2"
      [[ "$mode" == archive || "$mode" == print-and-archive ]] || {
        echo "ERROR: Invalid dispatch mode" >&2
        exit 1
      }
      [[ -f "$source" && ! -L "$source" ]] || {
        echo "ERROR: The submitted document is not a regular file" >&2
        exit 1
      }
      size="$(stat --format=%s -- "$source")"
      (( size > 0 && size <= ${toString cfg.maximumBytes} )) || {
        echo "ERROR: The submitted PDF is empty or exceeds the configured size limit" >&2
        exit 1
      }
      if qpdf --check "$source" >/dev/null 2>&1; then
        :
      else
        qpdf_status="$?"
        # qpdf uses status 3 for a usable PDF with recoverable warnings.
        ((qpdf_status == 3)) || {
          echo "ERROR: The submitted document is not a valid PDF" >&2
          exit 1
        }
      fi

      job_id="$(uuidgen --random)"
      incoming="${jobsDir}/.incoming-$job_id"
      final="${jobsDir}/$job_id"
      install -d -m 0700 -- "$incoming"
      trap 'rm -rf -- "$incoming"' EXIT
      install -m 0600 -- "$source" "$incoming/document.pdf"
      jq -n \
        --arg id "$job_id" \
        --arg mode "$mode" \
        --arg title "''${IPP_JOB_NAME:-}" \
        --arg user "''${IPP_REQUESTING_USER_NAME:-}" \
        --arg copies "''${IPP_COPIES:-1}" \
        --arg sides "''${IPP_SIDES:-}" \
        --arg media "''${IPP_MEDIA:-}" \
        --arg color "''${IPP_PRINT_COLOR_MODE:-}" \
        '{id:$id, mode:$mode, title:$title, user:$user, copies:$copies, sides:$sides, media:$media, color:$color}' \
        >"$incoming/job.json"
      touch "$incoming/archive.pending"
      if [[ "$mode" == print-and-archive ]]; then
        touch "$incoming/print.pending"
      fi
      sync -f "$incoming/document.pdf"
      sync -f "$incoming/job.json"
      mv --no-target-directory -- "$incoming" "$final"
      sync -f ${lib.escapeShellArg jobsDir}
      trap - EXIT
      echo "INFO: Accepted durable job $job_id" >&2
    '';
  };

  normalizeAndEnqueue =
    mode:
    pkgs.writeShellApplication {
      name = "normalize-paperless-${mode}-print";
      runtimeInputs = with pkgs; [
        coreutils
        cups
        cups-filters
      ];
      text = ''
        if [[ $# -ne 1 ]]; then
          echo "ERROR: Usage: normalize-paperless-${mode}-print DOCUMENT" >&2
          exit 1
        fi

        source="$1"
        [[ -f "$source" && ! -L "$source" ]] || {
          echo "ERROR: The submitted document is not a regular file" >&2
          exit 1
        }
        source_size="$(stat --format=%s -- "$source")"
        (( source_size > 0 && source_size <= ${toString cfg.maximumBytes} )) || {
          echo "ERROR: The submitted document is empty or exceeds the configured size limit" >&2
          exit 1
        }

        case "''${CONTENT_TYPE:-}" in
          application/pdf)
            exec ${lib.getExe enqueue} ${lib.escapeShellArg mode} "$source"
            ;;
          image/urf|image/jpeg)
            normalized="$(mktemp --tmpdir=${lib.escapeShellArg root} .normalized-XXXXXXXX.pdf)"
            trap 'rm -f -- "$normalized"' EXIT
            export CUPS_DATADIR=/var/lib/cups/path/share/cups
            export CUPS_SERVERBIN=/var/lib/cups/path/lib/cups
            cupsfilter \
              -i "$CONTENT_TYPE" \
              -m application/pdf \
              "$source" >"$normalized"
            ${lib.getExe enqueue} ${lib.escapeShellArg mode} "$normalized"
            rm -f -- "$normalized"
            trap - EXIT
            ;;
          *)
            echo "ERROR: Unsupported document format: ''${CONTENT_TYPE:-missing}" >&2
            exit 1
            ;;
        esac
      '';
    };

  normalizeArchive = normalizeAndEnqueue "archive";
  normalizePrintArchive = normalizeAndEnqueue "print-and-archive";

  saveCommand = pkgs.writeShellApplication {
    name = "paperless-save-command";
    text = ''
      exec ${lib.getExe normalizeArchive} "$@"
    '';
  };

  printSaveCommand = pkgs.writeShellApplication {
    name = "paperless-print-save-command";
    text = ''
      exec ${lib.getExe normalizePrintArchive} "$@"
    '';
  };

  archiveFilename = pkgs.writeText "paperless-print-filename.py" ''
    import json
    import re
    import sys
    import unicodedata

    with open(sys.argv[1], encoding="utf-8") as metadata:
        title = json.load(metadata).get("title") or ""
    if not isinstance(title, str):
        title = ""
    # The client supplies a title, never a path. Keep Unicode text while removing
    # path separators and control characters (including directional overrides).
    title = "".join(
        " " if character in "/\\" or unicodedata.category(character).startswith("C") else character
        for character in title
    )
    title = " ".join(title.split())
    title = re.sub(r"(?i)\.pdf$", "", title).strip(" .")
    # Paperless titles are at most 127 characters; Linux filenames have a byte
    # limit as well. Decode only complete UTF-8 characters after truncation.
    title = title[:127].encode("utf-8")[:240].decode("utf-8", errors="ignore").rstrip(" .")
    if not title:
        title = "virtual-printer-" + sys.argv[2]
    print(title + ".pdf")
  '';

  dispatch = pkgs.writeShellApplication {
    name = "dispatch-paperless-print-jobs";
    runtimeInputs = with pkgs; [
      coreutils
      cups
      findutils
      jq
      python3
    ];
    text = ''
      shopt -s nullglob

      for job in ${lib.escapeShellArg jobsDir}/*; do
        [[ -d "$job" && ! -L "$job" ]] || continue
        document="$job/document.pdf"
        metadata="$job/job.json"
        [[ -f "$document" && ! -L "$document" && -f "$metadata" && ! -L "$metadata" ]] || {
          echo "Malformed logical printer job: $job" >&2
          continue
        }
        job_id="$(basename -- "$job")"

        if [[ -e "$job/archive.pending" && ! -e "$job/archive.dispatching" ]]; then
          filename="$(python3 ${archiveFilename} "$metadata" "$job_id")"
          # A dispatching marker deliberately survives interruption. Automatically
          # retrying an ambiguous handoff could ingest the same document twice.
          touch "$job/archive.dispatching"
          destination="${consumptionDir}/virtual-printer-$job_id"
          target="$destination/$filename"
          if [[ -e "$target" || -L "$target" ]]; then
            echo "Paperless target already exists for job $job_id" >&2
          else
            install -d -o paperless -g paperless -m 0700 -- "$destination"
            temporary="$destination/.document.tmp"
            install -o paperless -g paperless -m 0600 -- "$document" "$temporary"
            mv --no-target-directory -- "$temporary" "$target"
            rm "$job/archive.pending"
            mv "$job/archive.dispatching" "$job/archive.done"
            echo "Dispatched $job_id to Paperless"
          fi
        fi

        if [[ -e "$job/print.pending" && ! -e "$job/print.dispatching" ]]; then
          touch "$job/print.dispatching"
          copies="$(jq -r '.copies // "1"' "$metadata")"
          sides="$(jq -r '.sides // ""' "$metadata")"
          media="$(jq -r '.media // ""' "$metadata")"
          color="$(jq -r '.color // ""' "$metadata")"
          options=()
          [[ "$copies" =~ ^[1-9][0-9]?$ ]] && options+=("-n" "$copies")
          case "$sides" in
            one-sided|two-sided-long-edge|two-sided-short-edge)
              options+=("-o" "sides=$sides")
              ;;
          esac
          [[ "$media" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && options+=("-o" "media=$media")
          case "$color" in
            auto|color|monochrome)
              options+=("-o" "print-color-mode=$color")
              ;;
          esac
          if output="$(lp -d ${lib.escapeShellArg physicalQueue} "''${options[@]}" "$document" 2>&1)"; then
            printf '%s\n' "$output" >"$job/physical-cups-job.txt"
            rm "$job/print.pending"
            mv "$job/print.dispatching" "$job/print.done"
            echo "Submitted $job_id to ${physicalQueue}: $output"
          else
            rm "$job/print.dispatching"
            echo "Physical dispatch failed for $job_id: $output" >&2
          fi
        fi
      done

      # Paperless removes consumed files, but leaves their per-job directories.
      # Directory deletion succeeds only while empty, preserving waiting files.
      find ${lib.escapeShellArg consumptionDir} -mindepth 1 -maxdepth 1 \
        -type d -name 'virtual-printer-*' -mtime +7 -empty -delete

      # Completed payloads are transient; Paperless and CUPS own the durable results.
      # $job expands in the nested Bash process.
      # shellcheck disable=SC2016
      find ${lib.escapeShellArg jobsDir} -mindepth 1 -maxdepth 1 -type d -mtime +7 \
        -exec ${pkgs.bash}/bin/bash -c 'for job do
          [[ -e "$job/archive.done" && ! -e "$job/archive.pending" && ! -e "$job/archive.dispatching" ]] || continue
          [[ ! -e "$job/print.pending" && ! -e "$job/print.dispatching" ]] || continue
          rm -rf -- "$job"
        done' sh {} +

      ambiguous="$(find ${lib.escapeShellArg jobsDir} -mindepth 2 -maxdepth 2 -type f \
        \( -name archive.dispatching -o -name print.dispatching \) -print -quit)"
      [[ -z "$ambiguous" ]] || {
        echo "Ambiguous logical-printer dispatch requires review: $ambiguous" >&2
        exit 1
      }
    '';
  };

  configurePhysicalPrinter = pkgs.writeShellApplication {
    name = "configure-physical-printer";
    runtimeInputs = [ pkgs.cups ];
    text = ''
      lpadmin -p ${lib.escapeShellArg physicalQueue} \
        -E \
        -v ${lib.escapeShellArg "ipp://${cfg.printerAddress}/ipp/print"} \
        -m everywhere \
        -o printer-is-shared=false
      lpadmin -d ${lib.escapeShellArg physicalQueue}
    '';
  };
in
{
  options.homelab.paperlessPrinter = {
    enable = lib.mkEnableOption "IPP logical printers backed by Paperless";
    printerAddress = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "192.168.4.21";
      description = "Stable LAN address of the downstream Epson ET-4950.";
    };
    savePort = lib.mkOption {
      type = lib.types.port;
      default = 8631;
      description = "IPP port for the Save to Paperless logical printer.";
    };
    printSavePort = lib.mkOption {
      type = lib.types.port;
      default = 8632;
      description = "IPP port for the Print and Save to Paperless logical printer.";
    };
    maximumBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 104857600;
      description = "Maximum accepted logical-printer document size in bytes.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.paperless.enable;
        message = "The Paperless logical printers require Paperless";
      }
      {
        assertion = cfg.savePort != cfg.printSavePort;
        message = "The two Paperless logical printers require distinct ports";
      }
    ];

    users = {
      groups.${serviceUser} = { };
      users.${serviceUser} = {
        isSystemUser = true;
        group = serviceUser;
        home = root;
      };
    };

    services = {
      paperless.settings = {
        PAPERLESS_CONSUMER_RECURSIVE = true;
        # Polling also discovers files when a new job directory is populated
        # before inotify has installed its recursive watch.
        PAPERLESS_CONSUMER_POLLING = 5;
      };
      printing = {
        enable = true;
        startWhenNeeded = false;
        listenAddresses = [ "localhost:631" ];
        browsing = false;
        defaultShared = false;
        browsed.enable = false;
      };
      avahi = {
        enable = true;
        openFirewall = false;
        publish = {
          enable = true;
          addresses = true;
        };
        extraServiceFiles = {
          paperless-save = ''
            <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
            <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
            <service-group>
              <name>Save to Paperless</name>
              <service>
                <type>_ipp._tcp</type>
                <subtype>_print._sub._ipp._tcp</subtype>
                <subtype>_universal._sub._ipp._tcp</subtype>
                <port>${toString cfg.savePort}</port>
                <txt-record>rp=ipp/print</txt-record>
                <txt-record>ty=Paperless PDF Archive</txt-record>
                <txt-record>pdl=image/urf,image/jpeg,application/pdf</txt-record>
                <txt-record>URF=CP1,IS1-4-5-7-19,MT1-2-3-4-5-6-8-9-10-11-12-13,RS600,SRGB24,V1.4,W8,DM3</txt-record>
                <txt-record>Color=T</txt-record>
                <txt-record>Duplex=T</txt-record>
                <txt-record>Copies=T</txt-record>
                <txt-record>air=none</txt-record>
                <txt-record>kind=document</txt-record>
                <txt-record>UUID=7c5cd48e-98be-4da2-95a7-a9c5f701215f</txt-record>
                <txt-record>txtvers=1</txt-record>
                <txt-record>qtotal=1</txt-record>
              </service>
            </service-group>
          '';
          paperless-print-save = ''
            <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
            <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
            <service-group>
              <name>Print and Save to Paperless</name>
              <service>
                <type>_ipp._tcp</type>
                <subtype>_print._sub._ipp._tcp</subtype>
                <subtype>_universal._sub._ipp._tcp</subtype>
                <port>${toString cfg.printSavePort}</port>
                <txt-record>rp=ipp/print</txt-record>
                <txt-record>ty=Epson ET-4950 and Paperless Archive</txt-record>
                <txt-record>pdl=image/urf,image/jpeg,application/pdf</txt-record>
                <txt-record>URF=CP1,IS1-4-5-7-19,MT1-2-3-4-5-6-8-9-10-11-12-13,RS600,SRGB24,V1.4,W8,DM3</txt-record>
                <txt-record>Color=T</txt-record>
                <txt-record>Duplex=T</txt-record>
                <txt-record>Copies=T</txt-record>
                <txt-record>air=none</txt-record>
                <txt-record>kind=document</txt-record>
                <txt-record>UUID=c3ec9d81-2a53-413b-a6b7-553ffb62f0d6</txt-record>
                <txt-record>txtvers=1</txt-record>
                <txt-record>qtotal=1</txt-record>
              </service>
            </service-group>
          '';
        };
      };
    };

    networking.firewall.extraCommands = lib.mkAfter ''
      iptables -w -A nixos-fw \
        -s ${lib.escapeShellArg config.homelab.firewall.lanIPv4Subnet} \
        -p tcp -m multiport --dports ${toString cfg.savePort},${toString cfg.printSavePort} \
        -j nixos-fw-accept
      iptables -w -A nixos-fw \
        -s ${lib.escapeShellArg config.homelab.firewall.lanIPv4Subnet} \
        -p udp --dport 5353 \
        -j nixos-fw-accept
    '';

    systemd = {
      tmpfiles.settings."00-paperless-printer" = {
        ${root}.d = {
          mode = "0700";
          user = serviceUser;
          group = serviceUser;
        };
        ${jobsDir}.d = {
          mode = "0700";
          user = serviceUser;
          group = serviceUser;
        };
        ${saveSpool}.d = {
          mode = "0700";
          user = serviceUser;
          group = serviceUser;
        };
        ${printSaveSpool}.d = {
          mode = "0700";
          user = serviceUser;
          group = serviceUser;
        };
        "${root}/.cups".d = {
          mode = "0700";
          user = serviceUser;
          group = serviceUser;
        };
        "${root}/.cups/ssl".d = {
          mode = "0700";
          user = serviceUser;
          group = serviceUser;
        };
      };

      services = {
        paperless-printer-configure = {
          description = "Configure the Epson ET-4950 driverless CUPS queue";
          wantedBy = [ "multi-user.target" ];
          after = [
            "cups.service"
            "network-online.target"
          ];
          wants = [
            "cups.service"
            "network-online.target"
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe configurePhysicalPrinter;
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = "30s";
          };
        };

        paperless-save-printer = {
          description = "Save to Paperless IPP printer";
          wantedBy = [ "multi-user.target" ];
          after = [
            "avahi-daemon.service"
            "cups.service"
            "systemd-tmpfiles-setup.service"
          ];
          wants = [
            "avahi-daemon.service"
            "cups.service"
          ];
          serviceConfig = {
            User = serviceUser;
            Group = serviceUser;
            WorkingDirectory = root;
            ExecStart = "${pkgs.cups}/bin/ippeveprinter -2 -r off -f application/pdf,image/urf,image/jpeg -F application/pdf -c ${lib.getExe saveCommand} -d ${saveSpool} -p ${toString cfg.savePort} -s 13,7 ${lib.escapeShellArg "Save to Paperless"}";
            Restart = "on-failure";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ root ];
          };
        };

        paperless-print-save-printer = {
          description = "Print and Save to Paperless IPP printer";
          wantedBy = [ "multi-user.target" ];
          after = [
            "avahi-daemon.service"
            "cups.service"
            "systemd-tmpfiles-setup.service"
          ];
          wants = [
            "avahi-daemon.service"
            "cups.service"
          ];
          serviceConfig = {
            User = serviceUser;
            Group = serviceUser;
            WorkingDirectory = root;
            ExecStart = "${pkgs.cups}/bin/ippeveprinter -2 -r off -f application/pdf,image/urf,image/jpeg -F application/pdf -c ${lib.getExe printSaveCommand} -d ${printSaveSpool} -p ${toString cfg.printSavePort} -s 13,7 ${lib.escapeShellArg "Print and Save to Paperless"}";
            Restart = "on-failure";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ root ];
          };
        };

        paperless-printer-dispatch = {
          description = "Dispatch durable logical printer jobs";
          after = [
            "cups.service"
            "paperless-printer-configure.service"
          ];
          wants = [ "cups.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";
            UMask = "0077";
            ExecStart = lib.getExe dispatch;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [
              jobsDir
              consumptionDir
            ];
          };
        };
      };

      timers.paperless-printer-dispatch = {
        description = "Dispatch queued logical printer jobs";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "15s";
          Unit = "paperless-printer-dispatch.service";
        };
      };
    };

    environment.systemPackages = [
      configurePhysicalPrinter
      dispatch
    ];
  };
}
