{ ... }:
{
  # Convert the persistent SSH host identity to an age identity at activation.
  # Encrypted secret declarations will be added by the service modules that use
  # them; keeping this module file-agnostic lets the base host deploy first.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  assertions = [
    {
      assertion = builtins.pathExists ../../.sops.yaml;
      message = "sops-nix requires the repository-root .sops.yaml policy";
    }
  ];
}
