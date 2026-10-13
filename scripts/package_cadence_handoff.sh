#!/usr/bin/env bash
#==============================================================================
# Package Cadence Handoff Bundle
# Creates a self-contained archive with RTL, constraints, Cadence scripts,
# and verification collateral for transfer to the Cadence Genus/Innovus machine.
#==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUTPUT_DIR="output"
mkdir -p "$OUTPUT_DIR"

COMMIT_HASH=$(git rev-parse --short HEAD)
ARCHIVE_NAME="cordic_adaptive11_cadence_handoff_${COMMIT_HASH}.tar.gz"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"

echo "=========================================================="
echo "Packaging Cadence Handoff Bundle"
echo "Commit:  ${COMMIT_HASH}"
echo "Branch:  $(git rev-parse --abbrev-ref HEAD)"
echo "Output:  ${ARCHIVE_PATH}"
echo "=========================================================="

tar --exclude='.git' \
    --exclude='obj_dir' \
    --exclude='output/*.tar.gz' \
    --exclude='output/*.vcd' \
    --exclude='tb/formal/cordic_formal_*' \
    -czf "${ARCHIVE_PATH}" \
    rtl \
    constraints \
    cadence \
    Makefile \
    PHASE1_IMPLEMENTATION_REPORT.md

CHECKSUM=$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')
echo "Archive created successfully!"
echo "SHA256: ${CHECKSUM}"
echo ""
echo "To transfer to remote Cadence server (e.g. 172.16.77.4):"
echo "  scp ${ARCHIVE_PATH} student19@172.16.77.4:~/"
echo "  ssh -X student19@172.16.77.4"
echo "  tar -xzf ${ARCHIVE_NAME}"
echo "  cd cadence && genus -f scripts/genus_synth.tcl"
echo "=========================================================="
