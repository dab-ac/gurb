{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            qemu
            OVMFFull.fd
            xorriso
            virtiofsd
            (perl.withPackages (p: [ p.LinuxInotify2 ]))
            python3Packages.virt-firmware
          ];

          shellHook = ''
            export OVMF_FV="${pkgs.OVMFFull.fd}/FV"
          '';
        };
      }
    );
}
