{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    nim
  ];

  buildInputs = with pkgs; [
    libx11
    libxft
  ];

  shellHook = ''
    export LD_LIBRARY_PATH="${pkgs.libx11}/lib:${pkgs.libxft}/lib:$LD_LIBRARY_PATH"
    echo "X11 development environment loaded!"
  '';
}

