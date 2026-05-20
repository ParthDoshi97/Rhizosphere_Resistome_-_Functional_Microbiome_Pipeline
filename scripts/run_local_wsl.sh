#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_local_wsl.sh - Run pipeline locally inside WSL with local input/output.
#
# Usage:
#   bash scripts/run_local_wsl.sh --input /path/to/sample_sheet.csv [--resume]
#
# Notes:
#   - Requires Docker Desktop with WSL2 integration enabled.
#   - The local profile caps the executor queue so only one total task runs at
#     a time on memory-limited WSL installs.
#   - Use scripts/run_local_wsl_s3.sh for S3 inputs/results.
#   - Use scripts/run_awsbatch.sh or scripts/run_awsbatch_instant.sh when the
#     assembly steps need more RAM than WSL can provide.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

INPUT="${NXF_LOCAL_INPUT:-}"
OUTDIR="${NXF_LOCAL_OUTDIR:-${REPO_DIR}/results}"
WORKDIR="${NXF_LOCAL_WORKDIR:-/tmp/nxf-work}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) INPUT="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$INPUT" ]]; then
    echo "ERROR: --input is required"
    echo "Usage: bash scripts/run_local_wsl.sh --input /path/to/sample_sheet.csv [--resume]"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker not found. Enable WSL2 integration in Docker Desktop."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running. Start Docker Desktop first."
    exit 1
fi

if ! command -v nextflow >/dev/null 2>&1; then
    echo "ERROR: Nextflow not found. Install with:"
    echo "  curl -s https://get.nextflow.io | bash && sudo mv nextflow /usr/local/bin/"
    exit 1
fi

echo "============================================================"
echo "  Rhizosphere Resistome Pipeline - LOCAL / WSL"
echo "------------------------------------------------------------"
echo "  Input:    $INPUT"
echo "  Output:   $OUTDIR"
echo "  Work dir: $WORKDIR"
echo "============================================================"

nextflow run "${REPO_DIR}/main.nf" \
    -profile local \
    -work-dir "$WORKDIR" \
    --input "$INPUT" \
    --outdir "$OUTDIR" \
    "${EXTRA_ARGS[@]}"
