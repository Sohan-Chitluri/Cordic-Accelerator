{
  description = "CORDIC ASIC Development Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
    };
  in
  {
    devShells.${system}.default =
      pkgs.mkShell {

        packages = with pkgs; [
          python3
          python3Packages.pip
          python3Packages.virtualenv
          gnumake
          gcc

          verilator
          yosys
          gtkwave

          z3
          sby
          git

          # P&R, DRC / LVS
          openroad
          magic-vlsi
          netgen

          # Build deps for standalone OpenSTA (built from source into ./tools/opensta,
          # see docs/PLACE_ROUTE_DRC.md). We build OpenSTA directly rather than pulling
          # nixpkgs' `openroad` package: nixpkgs' `openroad` depends on `or-tools`, which
          # was broken under Python 3.14 (pybind11's bundled test suite failed) on the
          # nixpkgs revision this project used to pin. That was fixed upstream in
          # nixpkgs PR #551898 (merged 2026-09-07) and this flake's nixpkgs input has
          # since been bumped past that fix — `nixpkgs#openroad` now builds. The
          # standalone OpenSTA build is kept here because it's already working and
          # much smaller than pulling in all of OpenROAD just for timing analysis.
          cmake
          tcl
          cudd
          eigen
          swig
          flex
          bison
          pkg-config
          zlib
          gtest
        ];

        shellHook = ''
          echo ""
          echo "CORDIC ASIC Development Environment"
          echo ""
          verilator --version
          yosys -V
          echo ""
          echo "Available tools:"
          echo "  verilator  -- lint/simulation"
          echo "  yosys      -- synthesis"
          echo "  gtkwave    -- waveform viewing"
          echo "  z3         -- SMT solver (formal)"
          echo "  sby        -- SymbiYosys formal verification"
          echo ""
          echo "  magic      -- DRC / layout"
          echo "  netgen     -- LVS"
          echo ""
          echo "  sta        -- build via: make -C tools sta  (standalone OpenSTA;"
          echo "                nixpkgs#openroad also works now, see docs/PLACE_ROUTE_DRC.md)"
          echo ""
          echo "PDK: Sky130 fetched separately via volare into ./pdk/ (see docs/PLACE_ROUTE_DRC.md)"
          echo ""
        '';
      };
  };
}
