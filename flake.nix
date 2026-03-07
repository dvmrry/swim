{
  description = "swim — minimalist vi-mode browser for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }: let
    systems = [ "aarch64-darwin" "x86_64-darwin" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    devShells = forAllSystems (system: let
      pkgs = import nixpkgs { inherit system; };
    in {
      default = pkgs.mkShell {
        name = "swim";

        packages = with pkgs; [
          clang-tools  # clangd LSP
        ];

        shellHook = ''
          echo "swim devshell ready"
          echo "  clang $(clang --version | head -1)"
        '';
      };
    });
  };
}
