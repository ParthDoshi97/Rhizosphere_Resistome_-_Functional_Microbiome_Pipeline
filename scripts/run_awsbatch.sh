#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/run_awsbatch.sh --input samples.csv --queue QUEUE --bucket-dir s3://bucket/prefix [options] [-- extra nextflow args]

Options:
  --region REGION          AWS region. Defaults to AWS_REGION, AWS_DEFAULT_REGION, or us-east-1.
  --outdir PATH            Output directory. Use s3://... for cloud results.
  --entry FILE             Nextflow entry file. Defaults to main.nf.
  --aws-profile PROFILE    AWS credential profile for the launcher.
  --aws-cli-path PATH      AWS CLI path on the Batch host AMI, if needed.
  --spot                   Use the awsbatch_spot profile.
  --fusion                 Use Wave + Fusion profiles for S3 access.
  --spot-attempts N        Spot reclaim retry attempts. Defaults to 5 with --spot, otherwise 0.
  --no-resume              Do not pass -resume.
  -h, --help               Show this help.
EOF
}

INPUT=""
QUEUE=""
BUCKET_DIR=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
OUTDIR=""
ENTRY="main.nf"
AWS_PROFILE_ARG=""
AWS_CLI_PATH=""
SPOT=0
FUSION=0
SPOT_ATTEMPTS=""
RESUME=1
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) INPUT="$2"; shift 2 ;;
        --queue) QUEUE="$2"; shift 2 ;;
        --bucket-dir) BUCKET_DIR="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --entry) ENTRY="$2"; shift 2 ;;
        --aws-profile) AWS_PROFILE_ARG="$2"; shift 2 ;;
        --aws-cli-path) AWS_CLI_PATH="$2"; shift 2 ;;
        --spot) SPOT=1; shift ;;
        --fusion) FUSION=1; shift ;;
        --spot-attempts) SPOT_ATTEMPTS="$2"; shift 2 ;;
        --no-resume) RESUME=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA_ARGS+=("$@"); break ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$INPUT" || -z "$QUEUE" || -z "$BUCKET_DIR" ]]; then
    usage
    exit 2
fi

if [[ ! "$BUCKET_DIR" =~ ^s3://[^/]+/.+ ]]; then
    echo "ERROR: --bucket-dir must be an S3 path with a bucket and prefix, for example s3://my-bucket/rhizo-work" >&2
    exit 2
fi

if ! command -v nextflow >/dev/null 2>&1; then
    echo "ERROR: nextflow is not available on PATH" >&2
    exit 127
fi

export AWS_REGION="$REGION"
export NXF_AWS_BATCH_QUEUE="$QUEUE"
export NXF_AWS_WORKDIR="$BUCKET_DIR"

if [[ -n "$OUTDIR" ]]; then
    export NXF_AWS_OUTDIR="$OUTDIR"
fi

if [[ -n "$AWS_PROFILE_ARG" ]]; then
    export AWS_PROFILE="$AWS_PROFILE_ARG"
fi

if [[ -n "$AWS_CLI_PATH" ]]; then
    export NXF_AWS_CLI_PATH="$AWS_CLI_PATH"
fi

if [[ -z "$SPOT_ATTEMPTS" ]]; then
    if [[ "$SPOT" -eq 1 ]]; then
        SPOT_ATTEMPTS=5
    else
        SPOT_ATTEMPTS=0
    fi
fi
export NXF_AWS_BATCH_MAX_SPOT_ATTEMPTS="$SPOT_ATTEMPTS"

if [[ "$SPOT" -eq 1 && "$FUSION" -eq 1 ]]; then
    PROFILE="awsbatch_spot_fusion"
elif [[ "$SPOT" -eq 1 ]]; then
    PROFILE="awsbatch_spot"
elif [[ "$FUSION" -eq 1 ]]; then
    PROFILE="awsbatch_fusion"
else
    PROFILE="awsbatch"
fi

CMD=(nextflow run "$ENTRY" -profile "$PROFILE" -bucket-dir "$BUCKET_DIR")
if [[ "$RESUME" -eq 1 ]]; then
    CMD+=(-resume)
fi
CMD+=(--input "$INPUT")
if [[ -n "$OUTDIR" ]]; then
    CMD+=(--outdir "$OUTDIR")
fi
CMD+=("${EXTRA_ARGS[@]}")

printf 'Running:'
printf ' %q' "${CMD[@]}"
printf '\n'
exec "${CMD[@]}"
