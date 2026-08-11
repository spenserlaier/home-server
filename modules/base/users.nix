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

  # SSH access is key-only, so requiring an unprovisioned account password here
  # would prevent the administrator from using sudo.
  security.sudo.wheelNeedsPassword = false;
}
