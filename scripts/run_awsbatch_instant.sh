#!/usr/bin/env bash
set -euo pipefail

# Hard-coded AWS Batch run command for this project.
# Run after setup:
#   bash scripts/run_awsbatch_instant.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.awsbatch.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

REGION="${AWS_REGION:-ap-south-1}"
QUEUE="${NXF_AWS_BATCH_QUEUE:-rhizo-spot-queue}"
BUCKET_DIR="${NXF_AWS_WORKDIR:-s3://nf-pipeline-data/Data/nxf-work}"
OUTDIR="${NXF_AWS_OUTDIR:-s3://nf-pipeline-data/Data/results}"
INPUT="${NXF_AWS_INPUT:-s3://nf-pipeline-data/Data/sample_sheet.csv}"
JOB_ROLE="${NXF_AWS_BATCH_JOB_ROLE:-}"

if [[ -z "$JOB_ROLE" ]]; then
    if ! command -v aws >/dev/null 2>&1; then
        echo "ERROR: .awsbatch.env not found and aws CLI is not available to resolve the account ID" >&2
        exit 1
    fi

    ACCOUNT_ID="$(aws --region "$REGION" sts get-caller-identity --query Account --output text)"
    JOB_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/rhizo-batch-job-role"
fi

exec bash "$SCRIPT_DIR/run_awsbatch.sh" \
    --input "$INPUT" \
    --queue "$QUEUE" \
    --bucket-dir "$BUCKET_DIR" \
    --region "$REGION" \
    --outdir "$OUTDIR" \
    --job-role "$JOB_ROLE" \
    --spot \
    --fusion \
    "$@"
