#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/setup_awsbatch.sh --bucket BUCKET [options]
  bash scripts/setup_awsbatch.sh --bucket-dir s3://bucket/prefix [options]

Creates or reuses the AWS resources needed to run this Nextflow pipeline on
AWS Batch from a Linux or EC2 launcher instance.

Required:
  --bucket BUCKET              S3 bucket for Nextflow work/results storage.
  --bucket-dir URI             S3 work directory. Sets --bucket and --work-prefix.

Options:
  --prefix NAME                Resource name prefix. Defaults to rhizo.
  --region REGION             AWS region. Defaults to AWS_REGION, AWS_DEFAULT_REGION, or us-east-1.
  --aws-profile PROFILE       AWS CLI credential profile to use.
  --queue NAME                Batch job queue name. Defaults to PREFIX-queue.
  --compute-env NAME          Batch compute environment name. Defaults to PREFIX-compute.
  --work-prefix PREFIX        S3 prefix for Nextflow work files. Defaults to rhizo-work.
  --results-prefix PREFIX     S3 prefix for pipeline results. Defaults to rhizo-results.
  --vpc-id VPC_ID             VPC for Batch instances. Defaults to the default VPC.
  --subnets IDS               Comma-separated subnet IDs. Defaults to all subnets in the VPC.
  --security-groups IDS       Comma-separated security group IDs. Defaults to PREFIX-batch-sg.
  --instance-types TYPES      Comma-separated EC2 instance types/families. Defaults to default_x86_64.
  --min-vcpus N               Minimum vCPUs. Defaults to 0.
  --desired-vcpus N           Desired vCPUs at creation. Defaults to 0.
  --max-vcpus N               Maximum vCPUs. Defaults to 256.
  --spot                      Create a Spot compute environment.
  --ec2                       Create an On-Demand EC2 compute environment. This is the default.
  --ec2-key-pair NAME         Optional EC2 key pair for Batch instances.
  --instance-role NAME        ECS instance role/profile name. Defaults to ecsInstanceRole.
  --job-role NAME             Batch job role name. Defaults to PREFIX-batch-job-role.
  --spot-fleet-role NAME      Spot fleet role name. Defaults to AmazonEC2SpotFleetTaggingRole.
  --env-file PATH             Write reusable exports for scripts/run_awsbatch.sh.
  -h, --help                  Show this help.

Example:
  bash scripts/setup_awsbatch.sh \
    --bucket my-rhizo-batch-bucket \
    --prefix rhizo \
    --region us-east-1 \
    --spot \
    --env-file .awsbatch.env
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '[setup-awsbatch] %s\n' "$*"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

parse_bucket_dir() {
    local uri="$1"
    local without_scheme

    [[ "$uri" =~ ^s3://[^/]+/.+ ]] || die "--bucket-dir must be an S3 path with a bucket and prefix, for example s3://nf-pipeline-data/Data/nxf-work"

    without_scheme="${uri#s3://}"
    BUCKET="${without_scheme%%/*}"
    WORK_PREFIX="${without_scheme#*/}"
}

json_array_from_csv() {
    local csv="$1"
    local first=1
    local item
    local value
    local -a values

    printf '['
    IFS=',' read -r -a values <<< "$csv"
    for item in "${values[@]}"; do
        value="$(trim "$item")"
        [[ -n "$value" ]] || continue
        if [[ "$first" -eq 0 ]]; then
            printf ','
        fi
        printf '"%s"' "${value//\"/\\\"}"
        first=0
    done
    printf ']'
}

join_with_commas() {
    local text="$1"
    printf '%s' "$text" | tr '\t\r\n ' ',' | sed -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//'
}

aws_cmd() {
    aws "${AWS_ARGS[@]}" "$@"
}

role_exists() {
    local role_name="$1"
    aws_cmd iam get-role --role-name "$role_name" >/dev/null 2>&1
}

get_role_arn() {
    local role_name="$1"
    aws_cmd iam get-role \
        --role-name "$role_name" \
        --query 'Role.Arn' \
        --output text
}

ensure_service_linked_role() {
    local service_name="$1"
    local role_name="$2"

    if role_exists "$role_name"; then
        log "IAM service-linked role exists: $role_name"
        return
    fi

    log "Creating IAM service-linked role for $service_name"
    aws_cmd iam create-service-linked-role \
        --aws-service-name "$service_name" >/dev/null
    IAM_CHANGED=1
}

ensure_role() {
    local role_name="$1"
    local trust_policy_file="$2"
    local description="$3"

    if role_exists "$role_name"; then
        log "IAM role exists: $role_name"
        return
    fi

    log "Creating IAM role: $role_name"
    aws_cmd iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document "file://$trust_policy_file" \
        --description "$description" >/dev/null
    IAM_CHANGED=1
}

attach_role_policy() {
    local role_name="$1"
    local policy_arn="$2"

    log "Ensuring managed policy on $role_name: $policy_arn"
    aws_cmd iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "$policy_arn" >/dev/null
    IAM_CHANGED=1
}

put_inline_policy() {
    local role_name="$1"
    local policy_name="$2"
    local policy_file="$3"

    log "Writing inline policy on $role_name: $policy_name"
    aws_cmd iam put-role-policy \
        --role-name "$role_name" \
        --policy-name "$policy_name" \
        --policy-document "file://$policy_file" >/dev/null
    IAM_CHANGED=1
}

ensure_instance_profile() {
    local profile_name="$1"
    local role_name="$2"
    local current_role

    if aws_cmd iam get-instance-profile --instance-profile-name "$profile_name" >/dev/null 2>&1; then
        log "IAM instance profile exists: $profile_name"
    else
        log "Creating IAM instance profile: $profile_name"
        aws_cmd iam create-instance-profile \
            --instance-profile-name "$profile_name" >/dev/null
        IAM_CHANGED=1
    fi

    current_role="$(
        aws_cmd iam get-instance-profile \
            --instance-profile-name "$profile_name" \
            --query 'InstanceProfile.Roles[0].RoleName' \
            --output text 2>/dev/null || true
    )"

    if [[ -z "$current_role" || "$current_role" == "None" ]]; then
        log "Adding $role_name to instance profile $profile_name"
        aws_cmd iam add-role-to-instance-profile \
            --instance-profile-name "$profile_name" \
            --role-name "$role_name" >/dev/null
        IAM_CHANGED=1
    elif [[ "$current_role" != "$role_name" ]]; then
        die "Instance profile $profile_name already contains role $current_role, not $role_name"
    else
        log "Instance profile $profile_name already contains $role_name"
    fi
}

ensure_bucket() {
    if aws_cmd s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
        log "S3 bucket exists: s3://$BUCKET"
    else
        log "Creating S3 bucket: s3://$BUCKET"
        if [[ "$REGION" == "us-east-1" ]]; then
            aws_cmd s3api create-bucket --bucket "$BUCKET" >/dev/null
        else
            aws_cmd s3api create-bucket \
                --bucket "$BUCKET" \
                --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
        fi
        aws_cmd s3api wait bucket-exists --bucket "$BUCKET"
    fi

    if aws_cmd s3api put-public-access-block \
        --bucket "$BUCKET" \
        --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null 2>&1; then
        log "S3 public access block is enabled for s3://$BUCKET"
    else
        log "WARN: could not set S3 public access block for s3://$BUCKET"
    fi
}

resolve_network() {
    local first_subnet
    local sg_name
    local sg_id

    if [[ -z "$VPC_ID" && -n "$SUBNETS" ]]; then
        first_subnet="$(printf '%s' "$SUBNETS" | cut -d',' -f1)"
        VPC_ID="$(
            aws_cmd ec2 describe-subnets \
                --subnet-ids "$first_subnet" \
                --query 'Subnets[0].VpcId' \
                --output text
        )"
    fi

    if [[ -z "$VPC_ID" ]]; then
        VPC_ID="$(
            aws_cmd ec2 describe-vpcs \
                --filters Name=is-default,Values=true \
                --query 'Vpcs[0].VpcId' \
                --output text
        )"
        [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || die "No default VPC found. Pass --vpc-id and --subnets."
    fi
    log "Using VPC: $VPC_ID"

    if [[ -z "$SUBNETS" ]]; then
        SUBNETS="$(
            aws_cmd ec2 describe-subnets \
                --filters Name=vpc-id,Values="$VPC_ID" \
                --query 'Subnets[].SubnetId' \
                --output text
        )"
        SUBNETS="$(join_with_commas "$SUBNETS")"
        [[ -n "$SUBNETS" ]] || die "No subnets found in VPC $VPC_ID"
    fi
    log "Using subnets: $SUBNETS"

    if [[ -z "$SECURITY_GROUPS" ]]; then
        sg_name="${PREFIX}-batch-sg"
        sg_id="$(
            aws_cmd ec2 describe-security-groups \
                --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$sg_name" \
                --query 'SecurityGroups[0].GroupId' \
                --output text
        )"

        if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
            log "Creating security group: $sg_name"
            sg_id="$(
                aws_cmd ec2 create-security-group \
                    --group-name "$sg_name" \
                    --description "AWS Batch compute environment for $PREFIX" \
                    --vpc-id "$VPC_ID" \
                    --query 'GroupId' \
                    --output text
            )"
            aws_cmd ec2 create-tags \
                --resources "$sg_id" \
                --tags "Key=Name,Value=$sg_name" "Key=Project,Value=$PREFIX" >/dev/null
        else
            log "Security group exists: $sg_name ($sg_id)"
        fi
        SECURITY_GROUPS="$sg_id"
    fi
    log "Using security groups: $SECURITY_GROUPS"
}

compute_environment_exists() {
    local status
    status="$(
        aws_cmd batch describe-compute-environments \
            --compute-environments "$COMPUTE_ENV" \
            --query 'computeEnvironments[0].computeEnvironmentName' \
            --output text
    )"
    [[ "$status" == "$COMPUTE_ENV" ]]
}

job_queue_exists() {
    local name
    name="$(
        aws_cmd batch describe-job-queues \
            --job-queues "$QUEUE" \
            --query 'jobQueues[0].jobQueueName' \
            --output text
    )"
    [[ "$name" == "$QUEUE" ]]
}

wait_for_compute_environment() {
    local status
    local reason
    local attempt

    for attempt in $(seq 1 60); do
        status="$(
            aws_cmd batch describe-compute-environments \
                --compute-environments "$COMPUTE_ENV" \
                --query 'computeEnvironments[0].status' \
                --output text
        )"

        if [[ "$status" == "VALID" ]]; then
            log "Compute environment is VALID: $COMPUTE_ENV"
            return
        fi

        if [[ "$status" == "INVALID" ]]; then
            reason="$(
                aws_cmd batch describe-compute-environments \
                    --compute-environments "$COMPUTE_ENV" \
                    --query 'computeEnvironments[0].statusReason' \
                    --output text
            )"
            die "Compute environment $COMPUTE_ENV is INVALID: $reason"
        fi

        log "Waiting for compute environment $COMPUTE_ENV to become VALID (current: $status)"
        sleep 10
    done

    die "Timed out waiting for compute environment $COMPUTE_ENV to become VALID"
}

create_compute_environment() {
    local compute_resources_file="$1"
    local tags_file="$2"

    if compute_environment_exists; then
        log "Batch compute environment exists: $COMPUTE_ENV"
    else
        log "Creating Batch compute environment: $COMPUTE_ENV"
        aws_cmd batch create-compute-environment \
            --compute-environment-name "$COMPUTE_ENV" \
            --type MANAGED \
            --state ENABLED \
            --compute-resources "file://$compute_resources_file" \
            --tags "file://$tags_file" >/dev/null
    fi

    wait_for_compute_environment
}

create_job_queue() {
    if job_queue_exists; then
        log "Batch job queue exists: $QUEUE"
        return
    fi

    log "Creating Batch job queue: $QUEUE"
    aws_cmd batch create-job-queue \
        --job-queue-name "$QUEUE" \
        --state ENABLED \
        --priority "$QUEUE_PRIORITY" \
        --compute-environment-order "order=1,computeEnvironment=$COMPUTE_ENV" \
        --tags "Project=$PREFIX,ManagedBy=setup_awsbatch.sh" >/dev/null
}

write_env_file() {
    local job_role_arn="$1"

    [[ -n "$ENV_FILE" ]] || return

    log "Writing reusable launcher environment: $ENV_FILE"
    cat > "$ENV_FILE" <<EOF
export AWS_REGION=$REGION
export NXF_AWS_BATCH_QUEUE=$QUEUE
export NXF_AWS_WORKDIR=s3://$BUCKET/$WORK_PREFIX
export NXF_AWS_OUTDIR=s3://$BUCKET/$RESULTS_PREFIX
export NXF_AWS_BATCH_JOB_ROLE=$job_role_arn
EOF
    if [[ "$COMPUTE_TYPE" == "SPOT" ]]; then
        cat >> "$ENV_FILE" <<EOF
export NXF_AWS_SPOT_QUEUE=$QUEUE
export NXF_AWS_BATCH_MAX_SPOT_ATTEMPTS=5
EOF
    fi
}

PREFIX="rhizo"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
AWS_PROFILE_ARG=""
BUCKET=""
WORK_PREFIX="rhizo-work"
RESULTS_PREFIX="rhizo-results"
QUEUE=""
COMPUTE_ENV=""
VPC_ID=""
SUBNETS=""
SECURITY_GROUPS=""
INSTANCE_TYPES="default_x86_64"
MIN_VCPUS=0
DESIRED_VCPUS=0
MAX_VCPUS=256
COMPUTE_TYPE="EC2"
ALLOCATION_STRATEGY="BEST_FIT_PROGRESSIVE"
EC2_KEY_PAIR=""
INSTANCE_ROLE="ecsInstanceRole"
JOB_ROLE=""
SPOT_FLEET_ROLE="AmazonEC2SpotFleetTaggingRole"
ENV_FILE=""
QUEUE_PRIORITY=10
IAM_CHANGED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket) BUCKET="$2"; shift 2 ;;
        --bucket-dir) parse_bucket_dir "$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --aws-profile) AWS_PROFILE_ARG="$2"; shift 2 ;;
        --queue) QUEUE="$2"; shift 2 ;;
        --compute-env) COMPUTE_ENV="$2"; shift 2 ;;
        --work-prefix) WORK_PREFIX="$2"; shift 2 ;;
        --results-prefix) RESULTS_PREFIX="$2"; shift 2 ;;
        --vpc-id) VPC_ID="$2"; shift 2 ;;
        --subnets) SUBNETS="$2"; shift 2 ;;
        --security-groups) SECURITY_GROUPS="$2"; shift 2 ;;
        --instance-types) INSTANCE_TYPES="$2"; shift 2 ;;
        --min-vcpus) MIN_VCPUS="$2"; shift 2 ;;
        --desired-vcpus) DESIRED_VCPUS="$2"; shift 2 ;;
        --max-vcpus) MAX_VCPUS="$2"; shift 2 ;;
        --spot) COMPUTE_TYPE="SPOT"; ALLOCATION_STRATEGY="SPOT_PRICE_CAPACITY_OPTIMIZED"; shift ;;
        --ec2) COMPUTE_TYPE="EC2"; ALLOCATION_STRATEGY="BEST_FIT_PROGRESSIVE"; shift ;;
        --ec2-key-pair) EC2_KEY_PAIR="$2"; shift 2 ;;
        --instance-role) INSTANCE_ROLE="$2"; shift 2 ;;
        --job-role) JOB_ROLE="$2"; shift 2 ;;
        --spot-fleet-role) SPOT_FLEET_ROLE="$2"; shift 2 ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -n "$BUCKET" ]] || { usage; exit 2; }

QUEUE="${QUEUE:-${PREFIX}-queue}"
COMPUTE_ENV="${COMPUTE_ENV:-${PREFIX}-compute}"
JOB_ROLE="${JOB_ROLE:-${PREFIX}-batch-job-role}"

if ! command -v aws >/dev/null 2>&1; then
    die "aws CLI is not installed or is not on PATH"
fi

export AWS_PAGER=""
AWS_ARGS=(--region "$REGION")
if [[ -n "$AWS_PROFILE_ARG" ]]; then
    AWS_ARGS+=(--profile "$AWS_PROFILE_ARG")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Using AWS region: $REGION"
if [[ -n "$AWS_PROFILE_ARG" ]]; then
    log "Using AWS profile: $AWS_PROFILE_ARG"
fi

aws_cmd sts get-caller-identity --query 'Account' --output text >/dev/null

ensure_bucket
resolve_network

cat > "$TMP_DIR/ec2-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

cat > "$TMP_DIR/ecs-task-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

cat > "$TMP_DIR/spot-fleet-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "spotfleet.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

cat > "$TMP_DIR/job-s3-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBatchBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Sid": "ReadWriteBatchObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::$BUCKET/*"
    },
    {
      "Sid": "WriteBatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    }
  ]
}
JSON

ensure_service_linked_role "batch.amazonaws.com" "AWSServiceRoleForBatch"

ensure_role "$INSTANCE_ROLE" "$TMP_DIR/ec2-trust.json" "ECS instance role for AWS Batch compute environments"
attach_role_policy "$INSTANCE_ROLE" "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
ensure_instance_profile "$INSTANCE_ROLE" "$INSTANCE_ROLE"

ensure_role "$JOB_ROLE" "$TMP_DIR/ecs-task-trust.json" "AWS Batch job role for Nextflow S3 access"
put_inline_policy "$JOB_ROLE" "${PREFIX}-nextflow-s3" "$TMP_DIR/job-s3-policy.json"
JOB_ROLE_ARN="$(get_role_arn "$JOB_ROLE")"

SPOT_FLEET_ROLE_ARN=""
if [[ "$COMPUTE_TYPE" == "SPOT" ]]; then
    ensure_service_linked_role "spot.amazonaws.com" "AWSServiceRoleForEC2Spot"
    ensure_service_linked_role "spotfleet.amazonaws.com" "AWSServiceRoleForEC2SpotFleet"
    ensure_role "$SPOT_FLEET_ROLE" "$TMP_DIR/spot-fleet-trust.json" "Spot Fleet role for AWS Batch Spot compute environments"
    attach_role_policy "$SPOT_FLEET_ROLE" "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
    SPOT_FLEET_ROLE_ARN="$(get_role_arn "$SPOT_FLEET_ROLE")"
fi

if [[ "$IAM_CHANGED" -eq 1 ]]; then
    log "Waiting briefly for IAM changes to propagate"
    sleep 20
fi

SUBNETS_JSON="$(json_array_from_csv "$SUBNETS")"
SECURITY_GROUPS_JSON="$(json_array_from_csv "$SECURITY_GROUPS")"
INSTANCE_TYPES_JSON="$(json_array_from_csv "$INSTANCE_TYPES")"

cat > "$TMP_DIR/compute-resources.json" <<JSON
{
  "type": "$COMPUTE_TYPE",
  "allocationStrategy": "$ALLOCATION_STRATEGY",
  "minvCpus": $MIN_VCPUS,
  "desiredvCpus": $DESIRED_VCPUS,
  "maxvCpus": $MAX_VCPUS,
  "instanceTypes": $INSTANCE_TYPES_JSON,
  "subnets": $SUBNETS_JSON,
  "securityGroupIds": $SECURITY_GROUPS_JSON,
  "instanceRole": "$INSTANCE_ROLE",
  "tags": {
    "Name": "$PREFIX-batch-instance",
    "Project": "$PREFIX",
    "ManagedBy": "setup_awsbatch.sh"
  }
JSON

if [[ "$COMPUTE_TYPE" == "SPOT" ]]; then
    printf ',\n  "spotIamFleetRole": "%s"' "$SPOT_FLEET_ROLE_ARN" >> "$TMP_DIR/compute-resources.json"
fi

if [[ -n "$EC2_KEY_PAIR" ]]; then
    printf ',\n  "ec2KeyPair": "%s"' "$EC2_KEY_PAIR" >> "$TMP_DIR/compute-resources.json"
fi
printf '\n}\n' >> "$TMP_DIR/compute-resources.json"

cat > "$TMP_DIR/batch-tags.json" <<JSON
{
  "Project": "$PREFIX",
  "ManagedBy": "setup_awsbatch.sh"
}
JSON

create_compute_environment "$TMP_DIR/compute-resources.json" "$TMP_DIR/batch-tags.json"
create_job_queue
write_env_file "$JOB_ROLE_ARN"

cat <<EOF

AWS Batch setup is ready.

Queue:        $QUEUE
Compute env:  $COMPUTE_ENV
Work dir:     s3://$BUCKET/$WORK_PREFIX
Results dir:  s3://$BUCKET/$RESULTS_PREFIX
Job role:     $JOB_ROLE_ARN

Run the pipeline with:

  bash scripts/run_awsbatch.sh \\
    --input s3://$BUCKET/path/to/sample_sheet.csv \\
    --queue $QUEUE \\
    --bucket-dir s3://$BUCKET/$WORK_PREFIX \\
    --region $REGION \\
EOF

if [[ "$COMPUTE_TYPE" == "SPOT" ]]; then
    cat <<EOF
    --outdir s3://$BUCKET/$RESULTS_PREFIX \\
    --job-role $JOB_ROLE_ARN \\
    --spot
EOF
else
    cat <<EOF
    --outdir s3://$BUCKET/$RESULTS_PREFIX \\
    --job-role $JOB_ROLE_ARN
EOF
fi

if [[ -n "$ENV_FILE" ]]; then
    cat <<EOF

Or reuse the saved environment:

  source $ENV_FILE
  bash scripts/run_awsbatch.sh --input s3://$BUCKET/path/to/sample_sheet.csv --queue "$QUEUE" --bucket-dir "\$NXF_AWS_WORKDIR" --outdir "\$NXF_AWS_OUTDIR"
EOF
fi
