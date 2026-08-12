{
  description = "NixOS configuration for the homeserver";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      disko,
      sops-nix,
      ...
    }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.homeserver = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./hosts/homeserver
        ];
      };

      apps.${system} = {
        disko = {
          type = "app";
          program = "${disko.packages.${system}.disko}/bin/disko";
          meta.description = "Pinned Disko CLI for the x86_64 NixOS installer";
        };
        disko-install = {
          type = "app";
          program = "${disko.packages.${system}.disko-install}/bin/disko-install";
          meta.description = "Pinned combined Disko and NixOS installer";
        };
      };

      checks.${system}.homeserver =
        inputs.self.nixosConfigurations.homeserver.config.system.build.toplevel;

      formatter = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "x86_64-linux"
      ] (targetSystem: nixpkgs.legacyPackages.${targetSystem}.nixfmt-tree);
    };
}
