# AWS Batch, S3, Spot, and Resume

This pipeline can run on AWS Batch with S3-backed work storage using the `awsbatch` profiles in `conf/awsbatch.config`.

## AWS Requirements

Create these AWS resources before launching, or use the reusable Linux setup script below:

- An AWS Batch compute environment.
- An AWS Batch job queue connected to that compute environment.
- An S3 bucket and prefix for the Nextflow remote work directory, for example `s3://my-bucket/rhizo-work`.
- IAM permissions for AWS Batch job submission, CloudWatch logs, and S3 read/write access to the input, work, and output buckets.

For Spot Instances, the AWS Batch compute environment backing the queue must be configured for EC2 Spot capacity. The pipeline profile then enables Nextflow Spot reclaim retries with `aws.batch.maxSpotAttempts`.

## Reusable Linux Setup

Run this once from any Linux or EC2 launcher instance with AWS CLI credentials that can create IAM, S3, EC2, and Batch resources:

For the project AWS Instant defaults, use the no-option setup script:

```bash
bash scripts/setup_awsbatch_instant.sh
```

It discovers the account, default VPC, and subnets; recreates the required IAM roles if they were deleted; creates or reuses the `rhizo-spot-ce` Spot compute environment and `rhizo-spot-queue`; uses `s3://multiomic-project-data/nxf-work` as the Nextflow work directory in `ap-south-1`; and writes `.awsbatch.env`.

After setup, run the project sample sheet with the no-option launcher:

```bash
bash scripts/run_awsbatch_instant.sh
```

To save a Seqera token once on the EC2 launcher, run:

```bash
bash scripts/set_seqera_token.sh
```

The token is written to `.awsbatch.env`, which is ignored by Git and sourced automatically by `scripts/run_awsbatch_instant.sh`.

For a custom setup, pass options to the generic setup script:

```bash
bash scripts/setup_awsbatch.sh \
  --bucket my-rhizo-batch-bucket \
  --prefix rhizo \
  --region us-east-1 \
  --spot \
  --env-file .awsbatch.env
```

The setup script is safe to rerun. It creates missing resources and reuses existing ones with the same names:

- S3 bucket for `-bucket-dir` work storage and results.
- AWS Batch service-linked role.
- ECS instance role and instance profile for EC2-backed Batch compute.
- Batch job role with S3 access for Nextflow tasks.
- Optional Spot Fleet roles when `--spot` is used.
- Security group, compute environment, and job queue.

After setup, either pass the queue/work paths directly or source the generated environment file:

```bash
source .awsbatch.env

bash scripts/run_awsbatch.sh \
  --input s3://my-rhizo-batch-bucket/path/to/sample_sheet.csv \
  --queue "$NXF_AWS_BATCH_QUEUE" \
  --bucket-dir "$NXF_AWS_WORKDIR" \
  --region "$AWS_REGION" \
  --outdir "$NXF_AWS_OUTDIR"
```

## Sample Sheet

Run the top-level pipeline with a CSV sample sheet:

```csv
id,site,timepoint,replicate,batch,exp_depth,reads_r1,reads_r2
MAIZE_RHZ_1,rhizosphere,T0,1,PRJNA647806,0,s3://bucket/reads/MAIZE_RHZ_1_R1.fastq.gz,s3://bucket/reads/MAIZE_RHZ_1_R2.fastq.gz
```

For multi-lane input, separate lane files with commas or semicolons inside the `reads_r1` and `reads_r2` columns. Quote comma-separated lane lists so they remain one CSV field. The FASTP process passes them to fastp as comma-separated inputs without concatenating files.

## Launch From PowerShell

```powershell
.\scripts\run_awsbatch.ps1 `
  -Input samples.csv `
  -Queue rhizo-batch-queue `
  -BucketDir s3://my-bucket/rhizo-work `
  -Region us-east-1 `
  -Outdir s3://my-bucket/rhizo-results
```

The PowerShell launcher passes `-resume` by default. Add `-NoResume` only when you intentionally want a fresh run.

## Launch On Linux Or EC2

```bash
bash scripts/run_awsbatch.sh \
  --input samples.csv \
  --queue rhizo-batch-queue \
  --bucket-dir s3://my-bucket/rhizo-work \
  --region us-east-1 \
  --outdir s3://my-bucket/rhizo-results \
  --job-role arn:aws:iam::123456789012:role/rhizo-batch-job-role
```

## Spot Queue

Use a queue backed by an AWS Batch EC2 Spot compute environment:

```bash
bash scripts/run_awsbatch.sh \
  --input samples.csv \
  --queue rhizo-spot-queue \
  --bucket-dir s3://my-bucket/rhizo-work \
  --outdir s3://my-bucket/rhizo-results \
  --spot \
  --spot-attempts 5
```

On PowerShell:

```powershell
.\scripts\run_awsbatch.ps1 `
  -Input samples.csv `
  -Queue rhizo-spot-queue `
  -BucketDir s3://my-bucket/rhizo-work `
  -Outdir s3://my-bucket/rhizo-results `
  -Spot `
  -SpotAttempts 5
```

## Fusion Option

Nextflow's current recommendation for AWS Batch + S3 is Wave containers plus Fusion file system, which avoids relying on the AWS CLI inside every task container. Use `--fusion` or `-Fusion` when your Nextflow/Fusion licensing and Seqera credentials are configured:

```bash
bash scripts/run_awsbatch.sh \
  --input samples.csv \
  --queue rhizo-spot-queue \
  --bucket-dir s3://my-bucket/rhizo-work \
  --outdir s3://my-bucket/rhizo-results \
  --spot \
  --fusion
```

Without Fusion, make sure the AWS CLI is available to Batch jobs, either in the container images or in the AWS Batch host AMI. If it is installed at a custom path on the AMI, pass it with `--aws-cli-path` or `-AwsCliPath`.

## Manual Command

The launch scripts expand to this general command:

```bash
nextflow run main.nf \
  -profile awsbatch_spot \
  -bucket-dir s3://my-bucket/rhizo-work \
  -resume \
  --input samples.csv \
  --outdir s3://my-bucket/rhizo-results
```

Use the same S3 work prefix and the same pipeline code when resuming, otherwise Nextflow will not find the cached tasks.
