{ config, lib, ... }:
let
  cfg = config.homelab.firewall;
in
{
  options.homelab.firewall.lanIPv4Subnet = lib.mkOption {
    type = lib.types.nonEmptyStr;
    example = "192.168.1.0/24";
    description = ''
      Trusted LAN IPv4 subnet allowed to reach home-server network services.
      Future overlay VPN ranges must be admitted separately rather than folded
      into this physical-LAN boundary.
    '';
  };

  config = {
    networking.firewall = {
      enable = true;
      # Keep the global port lists empty. These source-qualified rules run before
      # the NixOS firewall's final reject rule and intentionally have no IPv6
      # equivalent until a trusted IPv6 subnet is declared.
      extraCommands = ''
        iptables -w -A nixos-fw \
          -s ${lib.escapeShellArg cfg.lanIPv4Subnet} \
          -p tcp -m multiport --dports 22,53,80,443 \
          -j nixos-fw-accept
        iptables -w -A nixos-fw \
          -s ${lib.escapeShellArg cfg.lanIPv4Subnet} \
          -p udp -m multiport --dports 53,443 \
          -j nixos-fw-accept
      '';
    };
  };
}
