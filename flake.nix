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
          gnumake
          gcc

          verilator
          yosys
          gtkwave

          z3
          sby
          git
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
          echo "  gtkwave    -- waveform viewing"
          echo ""
          echo "Optional (not in base shell):"
          echo "  opensta    -- Static timing analysis (install separately if needed)"
          echo ""
        '';
      };
  };
}