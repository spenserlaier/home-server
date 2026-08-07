{ ... }:
{
  users.users.spenser-admin = {
    isNormalUser = true;
    description = "Homeserver administrator";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC0TQC9jgyIvsoI+Uj+Ta/I4B3QMC0usi2cLOvCu0FCp homeserver admin"
    ];
  };

  security.sudo.wheelNeedsPassword = true;
}
