{ config, ... }:
{
  assertions = [
    {
      assertion = config.fileSystems ? "/srv";
      message = ''
        /srv must be a dedicated filesystem or subvolume before persistent
        application state can be enabled
      '';
    }
  ];

  # Service modules own their immediate children of /srv and must declare those
  # directories alongside their users. The root stays traversable but writable
  # only by root.
  systemd.tmpfiles.rules = [
    "d /srv 0755 root root - -"
  ];
}
