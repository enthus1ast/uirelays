{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    nim
  ];

  buildInputs = with pkgs; [
    libX11
    libXft
  ];

  shellHook = ''
    export LD_LIBRARY_PATH="${pkgs.libX11}/lib:$LD_LIBRARY_PATH"
    echo "X11 development environment loaded!"
  '';
}

