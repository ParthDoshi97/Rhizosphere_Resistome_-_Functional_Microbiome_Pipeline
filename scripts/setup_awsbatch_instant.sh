#!/usr/bin/env bash
set -euo pipefail

# Hard-coded AWS Batch setup for this project on EC2/Instant.
# Run once:
#   bash scripts/setup_awsbatch_instant.sh

REGION="ap-south-1"
BUCKET="nf-pipeline-data"
WORK_PREFIX="Data/PRJNA647806/nxf-work"
RESULTS_PREFIX="Data/PRJNA647806/results"
SAMPLE_SHEET="s3://${BUCKET}/Data/sample_sheet.csv"

QUEUE_NAME="rhizo-spot-queue"
COMPUTE_ENV_NAME="rhizo-spot-ce"
SECURITY_GROUP_NAME="rhizo-batch-sg"

JOB_ROLE_NAME="rhizo-batch-job-role"
BATCH_SERVICE_ROLE_NAME="AWSBatchServiceRole"
INSTANCE_ROLE_NAME="ecsInstanceRole"
SPOT_FLEET_ROLE_NAME="AmazonEC2SpotFleetTaggingRole"

MIN_VCPUS=0
DESIRED_VCPUS=0
MAX_VCPUS=256
BID_PERCENTAGE=60
ENV_FILE=".awsbatch.env"

log() {
    printf '[setup-awsbatch-instant] %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

preserve_env_value() {
    local name="$1"
    local value="${!name:-}"

    if [[ -z "$value" && -f "$ENV_FILE" ]]; then
        value="$(
            bash -c 'source "$1" >/dev/null 2>&1 || true; eval "printf %s \"\${'"$name"':-}\""' _ "$ENV_FILE"
        )"
    fi

    printf '%s' "$value"
}

aws_cmd() {
    aws --region "$REGION" "$@"
}

role_exists() {
    aws_cmd iam get-role --role-name "$1" >/dev/null 2>&1
}

get_role_arn() {
    aws_cmd iam get-role --role-name "$1" --query 'Role.Arn' --output text
}

ensure_role() {
    local role_name="$1"
    local trust_policy="$2"
    local description="$3"

    if role_exists "$role_name"; then
        log "IAM role exists: $role_name"
        log "Refreshing trust policy for $role_name"
        aws_cmd iam update-assume-role-policy \
            --role-name "$role_name" \
            --policy-document "$trust_policy" >/dev/null
        return
    fi

    log "Creating IAM role: $role_name"
    aws_cmd iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document "$trust_policy" \
        --description "$description" >/dev/null
    IAM_CHANGED=1
}

attach_policy() {
    local role_name="$1"
    local policy_arn="$2"

    log "Ensuring policy on $role_name: $policy_arn"
    aws_cmd iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "$policy_arn" >/dev/null
    IAM_CHANGED=1
}

ensure_instance_profile() {
    local profile_name="$1"
    local role_name="$2"
    local current_role

    if aws_cmd iam get-instance-profile --instance-profile-name "$profile_name" >/dev/null 2>&1; then
        log "Instance profile exists: $profile_name"
    else
        log "Creating instance profile: $profile_name"
        aws_cmd iam create-instance-profile --instance-profile-name "$profile_name" >/dev/null
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
        die "Instance profile $profile_name already contains role $current_role"
    fi
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
        value="${item#"${item%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        [[ -n "$value" ]] || continue
        if [[ "$first" -eq 0 ]]; then
            printf ','
        fi
        printf '"%s"' "$value"
        first=0
    done
    printf ']'
}

resource_name_exists() {
    local service="$1"
    local query="$2"
    local expected="$3"
    shift 3

    local found
    found="$(aws_cmd "$service" "$@" --query "$query" --output text 2>/dev/null || true)"
    [[ "$found" == "$expected" ]]
}

compute_environment_status() {
    aws_cmd batch describe-compute-environments \
        --compute-environments "$COMPUTE_ENV_NAME" \
        --query 'computeEnvironments[0].status' \
        --output text 2>/dev/null || true
}

compute_environment_state() {
    aws_cmd batch describe-compute-environments \
        --compute-environments "$COMPUTE_ENV_NAME" \
        --query 'computeEnvironments[0].state' \
        --output text 2>/dev/null || true
}

compute_environment_reason() {
    aws_cmd batch describe-compute-environments \
        --compute-environments "$COMPUTE_ENV_NAME" \
        --query 'computeEnvironments[0].statusReason' \
        --output text 2>/dev/null || true
}

job_queue_status() {
    aws_cmd batch describe-job-queues \
        --job-queues "$QUEUE_NAME" \
        --query 'jobQueues[0].status' \
        --output text 2>/dev/null || true
}

job_queue_state() {
    aws_cmd batch describe-job-queues \
        --job-queues "$QUEUE_NAME" \
        --query 'jobQueues[0].state' \
        --output text 2>/dev/null || true
}

job_queue_exists() {
    resource_name_exists batch 'jobQueues[0].jobQueueName' "$QUEUE_NAME" describe-job-queues --job-queues "$QUEUE_NAME"
}

compute_environment_exists() {
    resource_name_exists batch 'computeEnvironments[0].computeEnvironmentName' "$COMPUTE_ENV_NAME" describe-compute-environments --compute-environments "$COMPUTE_ENV_NAME"
}

wait_for_job_queue_deleted() {
    for _ in $(seq 1 60); do
        if ! job_queue_exists; then
            log "Job queue deleted: $QUEUE_NAME"
            return
        fi
        log "Waiting for job queue deletion: $QUEUE_NAME"
        sleep 5
    done

    die "Timed out waiting for job queue $QUEUE_NAME to be deleted"
}

wait_for_compute_environment_deleted() {
    for _ in $(seq 1 60); do
        if ! compute_environment_exists; then
            log "Compute environment deleted: $COMPUTE_ENV_NAME"
            return
        fi
        log "Waiting for compute environment deletion: $COMPUTE_ENV_NAME"
        sleep 5
    done

    die "Timed out waiting for compute environment $COMPUTE_ENV_NAME to be deleted"
}

wait_for_job_queue_disabled() {
    local status
    local state

    for _ in $(seq 1 60); do
        if ! job_queue_exists; then
            return
        fi

        status="$(job_queue_status)"
        state="$(job_queue_state)"

        if [[ "$state" == "DISABLED" && "$status" != "UPDATING" ]]; then
            log "Job queue is disabled: $QUEUE_NAME"
            return
        fi

        log "Waiting for job queue to finish disabling: $QUEUE_NAME (state: $state, status: $status)"
        sleep 5
    done

    die "Timed out waiting for job queue $QUEUE_NAME to disable"
}

wait_for_compute_environment_disabled() {
    local status
    local state

    for _ in $(seq 1 60); do
        if ! compute_environment_exists; then
            return
        fi

        status="$(compute_environment_status)"
        state="$(compute_environment_state)"

        if [[ "$state" == "DISABLED" && "$status" != "UPDATING" ]]; then
            log "Compute environment is disabled: $COMPUTE_ENV_NAME"
            return
        fi

        log "Waiting for compute environment to finish disabling: $COMPUTE_ENV_NAME (state: $state, status: $status)"
        sleep 5
    done

    die "Timed out waiting for compute environment $COMPUTE_ENV_NAME to disable"
}

delete_job_queue_if_exists() {
    local error_file

    if ! job_queue_exists; then
        return
    fi

    log "Deleting project job queue before compute environment repair: $QUEUE_NAME"
    aws_cmd batch update-job-queue \
        --job-queue "$QUEUE_NAME" \
        --state DISABLED >/dev/null || true

    wait_for_job_queue_disabled

    error_file="$TMP_DIR/delete-job-queue.err"
    for _ in $(seq 1 60); do
        if aws_cmd batch delete-job-queue --job-queue "$QUEUE_NAME" >/dev/null 2>"$error_file"; then
            wait_for_job_queue_deleted
            return
        fi

        if ! job_queue_exists; then
            log "Job queue deleted: $QUEUE_NAME"
            return
        fi

        log "Job queue delete is not ready yet: $(tr '\n' ' ' < "$error_file")"
        sleep 10
    done

    die "Timed out deleting job queue $QUEUE_NAME"
}

delete_compute_environment_if_exists() {
    local error_file

    if ! compute_environment_exists; then
        return
    fi

    log "Deleting invalid project compute environment: $COMPUTE_ENV_NAME"
    aws_cmd batch update-compute-environment \
        --compute-environment "$COMPUTE_ENV_NAME" \
        --state DISABLED >/dev/null || true

    wait_for_compute_environment_disabled

    error_file="$TMP_DIR/delete-compute-environment.err"
    for _ in $(seq 1 60); do
        if aws_cmd batch delete-compute-environment --compute-environment "$COMPUTE_ENV_NAME" >/dev/null 2>"$error_file"; then
            wait_for_compute_environment_deleted
            return
        fi

        if ! compute_environment_exists; then
            log "Compute environment deleted: $COMPUTE_ENV_NAME"
            return
        fi

        log "Compute environment delete is not ready yet: $(tr '\n' ' ' < "$error_file")"
        sleep 10
    done

    die "Timed out deleting compute environment $COMPUTE_ENV_NAME"
}

repair_invalid_compute_environment() {
    local status
    local reason

    if ! compute_environment_exists; then
        return
    fi

    status="$(compute_environment_status)"
    if [[ "$status" != "INVALID" ]]; then
        return
    fi

    reason="$(compute_environment_reason)"
    log "Compute environment $COMPUTE_ENV_NAME is INVALID: $reason"
    log "Recreating it so AWS Batch can use the refreshed IAM roles"
    delete_job_queue_if_exists
    delete_compute_environment_if_exists
}

wait_for_compute_environment() {
    local status
    local reason

    for _ in $(seq 1 60); do
        status="$(
            aws_cmd batch describe-compute-environments \
                --compute-environments "$COMPUTE_ENV_NAME" \
                --query 'computeEnvironments[0].status' \
                --output text
        )"

        if [[ "$status" == "VALID" ]]; then
            log "Compute environment is VALID: $COMPUTE_ENV_NAME"
            return
        fi

        if [[ "$status" == "INVALID" ]]; then
            reason="$(
                aws_cmd batch describe-compute-environments \
                    --compute-environments "$COMPUTE_ENV_NAME" \
                    --query 'computeEnvironments[0].statusReason' \
                    --output text
            )"
            die "Compute environment $COMPUTE_ENV_NAME is INVALID: $reason"
        fi

        log "Waiting for compute environment $COMPUTE_ENV_NAME (current: $status)"
        sleep 10
    done

    die "Timed out waiting for compute environment $COMPUTE_ENV_NAME"
}

wait_for_job_queue() {
    local status
    local reason

    for _ in $(seq 1 60); do
        status="$(
            aws_cmd batch describe-job-queues \
                --job-queues "$QUEUE_NAME" \
                --query 'jobQueues[0].status' \
                --output text
        )"

        if [[ "$status" == "VALID" ]]; then
            log "Job queue is VALID: $QUEUE_NAME"
            return
        fi

        if [[ "$status" == "INVALID" ]]; then
            reason="$(
                aws_cmd batch describe-job-queues \
                    --job-queues "$QUEUE_NAME" \
                    --query 'jobQueues[0].statusReason' \
                    --output text
            )"
            die "Job queue $QUEUE_NAME is INVALID: $reason"
        fi

        log "Waiting for job queue $QUEUE_NAME (current: $status)"
        sleep 10
    done

    die "Timed out waiting for job queue $QUEUE_NAME"
}

if ! command -v aws >/dev/null 2>&1; then
    die "aws CLI is not installed or is not on PATH"
fi

export AWS_PAGER=""
IAM_CHANGED=0
PRESERVED_TOWER_ACCESS_TOKEN="$(preserve_env_value TOWER_ACCESS_TOKEN)"
PRESERVED_TOWER_API_ENDPOINT="$(preserve_env_value TOWER_API_ENDPOINT)"

log "Using fixed region: $REGION"
ACCOUNT_ID="$(aws_cmd sts get-caller-identity --query Account --output text)"
log "Account: $ACCOUNT_ID"

VPC_ID="$(
    aws_cmd ec2 describe-vpcs \
        --filters Name=is-default,Values=true \
        --query 'Vpcs[0].VpcId' \
        --output text
)"
[[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || die "No default VPC found in $REGION"

SUBNET_IDS="$(
    aws_cmd ec2 describe-subnets \
        --filters Name=vpc-id,Values="$VPC_ID" \
        --query 'Subnets[*].SubnetId' \
        --output text
)"
SUBNET_IDS="$(printf '%s' "$SUBNET_IDS" | tr '\t\r\n ' ',' | sed -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//')"
[[ -n "$SUBNET_IDS" ]] || die "No subnets found in VPC $VPC_ID"

log "VPC: $VPC_ID"
log "Subnets: $SUBNET_IDS"

SECURITY_GROUP_ID="$(
    aws_cmd ec2 describe-security-groups \
        --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$SECURITY_GROUP_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text
)"

if [[ -z "$SECURITY_GROUP_ID" || "$SECURITY_GROUP_ID" == "None" ]]; then
    log "Creating security group: $SECURITY_GROUP_NAME"
    SECURITY_GROUP_ID="$(
        aws_cmd ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "AWS Batch security group for rhizosphere pipeline" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text
    )"
    aws_cmd ec2 create-tags \
        --resources "$SECURITY_GROUP_ID" \
        --tags Key=Name,Value="$SECURITY_GROUP_NAME" Key=Project,Value=rhizo >/dev/null
else
    log "Security group exists: $SECURITY_GROUP_NAME ($SECURITY_GROUP_ID)"
fi

JOB_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

BATCH_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "batch.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

EC2_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

SPOT_FLEET_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "spotfleet.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

ensure_role "$JOB_ROLE_NAME" "$JOB_TRUST" "Nextflow AWS Batch job role"
attach_policy "$JOB_ROLE_NAME" "arn:aws:iam::aws:policy/AmazonS3FullAccess"
attach_policy "$JOB_ROLE_NAME" "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
attach_policy "$JOB_ROLE_NAME" "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
JOB_ROLE_ARN="$(get_role_arn "$JOB_ROLE_NAME")"

ensure_role "$BATCH_SERVICE_ROLE_NAME" "$BATCH_TRUST" "AWS Batch service role"
attach_policy "$BATCH_SERVICE_ROLE_NAME" "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
BATCH_SERVICE_ROLE_ARN="$(get_role_arn "$BATCH_SERVICE_ROLE_NAME")"

ensure_role "$INSTANCE_ROLE_NAME" "$EC2_TRUST" "ECS instance role for AWS Batch compute"
attach_policy "$INSTANCE_ROLE_NAME" "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
ensure_instance_profile "$INSTANCE_ROLE_NAME" "$INSTANCE_ROLE_NAME"
INSTANCE_PROFILE_ARN="arn:aws:iam::${ACCOUNT_ID}:instance-profile/${INSTANCE_ROLE_NAME}"

ensure_role "$SPOT_FLEET_ROLE_NAME" "$SPOT_FLEET_TRUST" "Spot Fleet role for AWS Batch Spot compute"
attach_policy "$SPOT_FLEET_ROLE_NAME" "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
SPOT_FLEET_ROLE_ARN="$(get_role_arn "$SPOT_FLEET_ROLE_NAME")"

if [[ "$IAM_CHANGED" -eq 1 ]]; then
    log "Waiting briefly for IAM propagation"
    sleep 20
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SUBNETS_JSON="$(json_array_from_csv "$SUBNET_IDS")"
cat > "$TMP_DIR/compute-resources.json" <<JSON
{
  "type": "SPOT",
  "allocationStrategy": "SPOT_CAPACITY_OPTIMIZED",
  "minvCpus": $MIN_VCPUS,
  "desiredvCpus": $DESIRED_VCPUS,
  "maxvCpus": $MAX_VCPUS,
  "instanceTypes": ["optimal"],
  "subnets": $SUBNETS_JSON,
  "securityGroupIds": ["$SECURITY_GROUP_ID"],
  "instanceRole": "$INSTANCE_PROFILE_ARN",
  "bidPercentage": $BID_PERCENTAGE,
  "spotIamFleetRole": "$SPOT_FLEET_ROLE_ARN"
}
JSON

repair_invalid_compute_environment

if compute_environment_exists; then
    log "Compute environment exists: $COMPUTE_ENV_NAME"
else
    log "Creating compute environment: $COMPUTE_ENV_NAME"
    aws_cmd batch create-compute-environment \
        --compute-environment-name "$COMPUTE_ENV_NAME" \
        --type MANAGED \
        --state ENABLED \
        --compute-resources "file://$TMP_DIR/compute-resources.json" \
        --service-role "$BATCH_SERVICE_ROLE_ARN" >/dev/null
fi
wait_for_compute_environment

if job_queue_exists; then
    log "Job queue exists: $QUEUE_NAME"
else
    log "Creating job queue: $QUEUE_NAME"
    aws_cmd batch create-job-queue \
        --job-queue-name "$QUEUE_NAME" \
        --state ENABLED \
        --priority 1 \
        --compute-environment-order "order=1,computeEnvironment=$COMPUTE_ENV_NAME" >/dev/null
fi
wait_for_job_queue

cat > "$ENV_FILE" <<EOF
export AWS_REGION=$REGION
export AWS_DEFAULT_REGION=$REGION
export NXF_AWS_BATCH_QUEUE=$QUEUE_NAME
export NXF_AWS_SPOT_QUEUE=$QUEUE_NAME
export NXF_AWS_WORKDIR=s3://$BUCKET/$WORK_PREFIX
export NXF_AWS_OUTDIR=s3://$BUCKET/$RESULTS_PREFIX
export NXF_AWS_INPUT=$SAMPLE_SHEET
export NXF_AWS_BATCH_JOB_ROLE=$JOB_ROLE_ARN
export NXF_AWS_BATCH_MAX_SPOT_ATTEMPTS=5
EOF

if [[ -n "$PRESERVED_TOWER_ACCESS_TOKEN" ]]; then
    cat >> "$ENV_FILE" <<EOF
export TOWER_ACCESS_TOKEN='$PRESERVED_TOWER_ACCESS_TOKEN'
EOF
fi

if [[ -n "$PRESERVED_TOWER_API_ENDPOINT" ]]; then
    cat >> "$ENV_FILE" <<EOF
export TOWER_API_ENDPOINT='$PRESERVED_TOWER_API_ENDPOINT'
EOF
fi

cat <<EOF

AWS Batch Instant setup is ready.

Account:      $ACCOUNT_ID
Region:       $REGION
VPC:          $VPC_ID
Subnets:      $SUBNET_IDS
Compute env:  $COMPUTE_ENV_NAME
Queue:        $QUEUE_NAME
Work dir:     s3://$BUCKET/$WORK_PREFIX
Job role:     $JOB_ROLE_ARN
Env file:     $ENV_FILE

Run the pipeline every time with:

  bash scripts/run_awsbatch_instant.sh

Or manually:

  source $ENV_FILE
  bash scripts/run_awsbatch.sh \\
    --input $SAMPLE_SHEET \\
    --queue "$QUEUE_NAME" \\
    --bucket-dir "s3://$BUCKET/$WORK_PREFIX" \\
    --region "$REGION" \\
    --spot
EOF
