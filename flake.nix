{
  description = "saga_http dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    # saga.url = "github:dylantf/saga";
    # saga.inputs.nixpkgs.follows = "nixpkgs";
    # saga.inputs.flake-utils.follows = "flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      # saga,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            # saga.packages.${system}.default
            pkgs.erlang
            pkgs.rebar3
          ];
        };
      }
    );
}
