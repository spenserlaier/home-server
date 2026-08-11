{ lib, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    # replace this id with the id of the drive of the system where we deploy
    # (can be found by running `ls -l /dev/disk/by-id` from the machine running nix)
    device = lib.mkDefault "/dev/disk/by-id/nvme-GMK_512GB_2025110702513";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };

        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "@root" = {
                mountpoint = "/";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
              "@srv" = {
                mountpoint = "/srv";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
              "@log" = {
                mountpoint = "/var/log";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
            };
          };
        };
      };
    };
  };
}
