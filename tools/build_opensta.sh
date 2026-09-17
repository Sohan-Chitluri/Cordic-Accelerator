#!/usr/bin/env bash
# Builds standalone OpenSTA from source into tools/OpenSTA/build/sta.
#
# Why standalone instead of nixpkgs' `openroad` package: openroad depends on
# or-tools, which pulls in pybind11's bundled test suite. That suite currently
# fails to build under Python 3.14 on nixpkgs-unstable (an upstream nixpkgs
# packaging issue, unrelated to this project). OpenSTA itself has no or-tools
# dependency, so building it directly sidesteps the problem. Run this from
# inside `nix develop` (flake.nix provides cmake, tcl, cudd, eigen, swig,
# flex, bison, gtest).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -d OpenSTA ]; then
  git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenSTA.git
fi

mkdir -p OpenSTA/build
cd OpenSTA/build
cmake -DCMAKE_BUILD_TYPE=RELEASE ..
make -j"$(nproc)"

echo ""
echo "Built: $(pwd)/sta"
