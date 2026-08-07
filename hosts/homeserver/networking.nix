{ ... }:
{
  networking = {
    useDHCP = false;
    useNetworkd = true;
  };

  systemd.network = {
    enable = true;
    wait-online.anyInterface = true;

    networks."10-lan" = {
      matchConfig.Name = [
        "en*"
        "eth*"
      ];
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };
}
