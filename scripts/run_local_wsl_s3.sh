#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/run_local_wsl_s3.sh [--input SAMPLE_SHEET] [--outdir s3://bucket/results] [options] [-- extra nextflow args]

Options:
  --input PATH           Sample sheet. Defaults to s3://nf-pipeline-data/Data/PRJNA647806/sample_sheet.csv.
  --outdir s3://PATH     S3 results prefix. Defaults to s3://nf-pipeline-data/Data/PRJNA647806/results.
  --workdir PATH         Local WSL work directory. Defaults to /tmp/nxf-work.
  --region REGION        AWS region. Defaults to AWS_REGION, AWS_DEFAULT_REGION, or ap-south-1.
  --aws-profile PROFILE  AWS credential profile for the launcher.
  --no-resume            Do not pass -resume.
  -h, --help             Show this help.

Notes:
  S3 reduces local storage pressure for inputs/results, but the tasks still run
  inside WSL and Docker. If assembly fails because WSL has too little RAM, run
  the AWS Batch launcher instead.
EOF
}

s3_bucket() {
    local uri="$1"
    local without_scheme="${uri#s3://}"
    printf '%s\n' "${without_scheme%%/*}"
}

check_s3_bucket() {
    local uri="$1"
    local bucket
    bucket="$(s3_bucket "$uri")"

    if [[ -z "$bucket" || "$bucket" == "$uri" ]]; then
        echo "ERROR: invalid S3 path: $uri" >&2
        exit 2
    fi

    aws --region "$REGION" s3api head-bucket --bucket "$bucket" >/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

INPUT="${NXF_S3_INPUT:-s3://nf-pipeline-data/Data/PRJNA647806/sample_sheet.csv}"
OUTDIR="${NXF_S3_OUTDIR:-s3://nf-pipeline-data/Data/PRJNA647806/results}"
WORKDIR="${NXF_LOCAL_WORKDIR:-/tmp/nxf-work}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-south-1}}"
AWS_PROFILE_ARG="${AWS_PROFILE:-}"
RESUME=1
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) INPUT="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --aws-profile) AWS_PROFILE_ARG="$2"; shift 2 ;;
        --no-resume) RESUME=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA_ARGS+=("$@"); break ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$INPUT" || -z "$OUTDIR" ]]; then
    usage
    exit 2
fi

if [[ ! "$OUTDIR" =~ ^s3://[^/]+/.+ ]]; then
    echo "ERROR: --outdir must be an S3 path with a bucket and prefix, for example s3://my-bucket/rhizo-results" >&2
    exit 2
fi

if [[ "$INPUT" == s3://* && ! "$INPUT" =~ ^s3://[^/]+/.+ ]]; then
    echo "ERROR: S3 --input must include a bucket and sample sheet key, for example s3://my-bucket/project/sample_sheet.csv" >&2
    exit 2
fi

if [[ "$WORKDIR" == s3://* ]]; then
    echo "ERROR: WSL local runs need a local --workdir. Use scripts/run_awsbatch.sh for S3 work storage." >&2
    exit 2
fi

if [[ "$INPUT" != s3://* && ! -f "$INPUT" ]]; then
    echo "ERROR: local input sample sheet does not exist: $INPUT" >&2
    exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker not found. Enable WSL2 integration in Docker Desktop." >&2
    exit 127
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running. Start Docker Desktop first." >&2
    exit 1
fi

if ! command -v nextflow >/dev/null 2>&1; then
    echo "ERROR: Nextflow not found. Install with:" >&2
    echo "  curl -s https://get.nextflow.io | bash && sudo mv nextflow /usr/local/bin/" >&2
    exit 127
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: AWS CLI is required for the WSL S3 launcher." >&2
    echo "Install it in WSL and run: aws configure" >&2
    exit 127
fi

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

if [[ -n "$AWS_PROFILE_ARG" ]]; then
    export AWS_PROFILE="$AWS_PROFILE_ARG"
fi

if ! aws --region "$REGION" sts get-caller-identity >/dev/null; then
    echo "ERROR: AWS credentials are not available in WSL." >&2
    echo "Run aws configure, export AWS_PROFILE, or pass --aws-profile." >&2
    exit 1
fi

if [[ "$INPUT" == s3://* ]]; then
    check_s3_bucket "$INPUT"
    if ! aws --region "$REGION" s3 ls "$INPUT" >/dev/null; then
        echo "ERROR: S3 input sample sheet was not found or is not readable: $INPUT" >&2
        exit 1
    fi
fi
check_s3_bucket "$OUTDIR"

mkdir -p "$WORKDIR"

export NXF_S3_INPUT="$INPUT"
export NXF_S3_OUTDIR="$OUTDIR"

CMD=(nextflow run "${REPO_DIR}/main.nf" -profile local_s3 -work-dir "$WORKDIR")
if [[ "$RESUME" -eq 1 ]]; then
    CMD+=(-resume)
fi
CMD+=(--input "$INPUT" --outdir "$OUTDIR")
CMD+=("${EXTRA_ARGS[@]}")

echo "============================================================"
echo "  Rhizosphere Resistome Pipeline - LOCAL WSL + S3"
echo "------------------------------------------------------------"
echo "  Input:    $INPUT"
echo "  Output:   $OUTDIR"
echo "  Work dir: $WORKDIR"
echo "  Region:   $REGION"
echo "============================================================"
echo "Reminder: S3 helps storage; AWS Batch is the fix for true RAM limits."
printf 'Running:'
printf ' %q' "${CMD[@]}"
printf '\n'

exec "${CMD[@]}"
