# WSL Runs With S3 Storage

This pipeline can be launched from WSL with S3 input and output paths. This is
useful when local disk space is tight, because Nextflow can read FASTQ files
from S3 and publish results back to S3.

Important: S3 is storage, not RAM. A WSL local run still executes MEGAHIT,
Plass, CoverM, and fastp inside Docker on your laptop. If a step fails because
there is not enough memory, use AWS Batch from WSL instead of local execution.

## When To Use Each Launcher

- Use `scripts/run_local_wsl.sh` for local sample sheets, local reads, and
  local results.
- Use `scripts/run_local_wsl_s3.sh` when WSL has enough RAM but you want S3
  inputs and S3 results.
- Use `scripts/run_awsbatch.sh` or `scripts/run_awsbatch_instant.sh` when WSL
  memory is the blocker. WSL only launches the run; AWS Batch executes the
  heavy jobs with cloud memory.

## WSL S3 Prerequisites

Install and configure these inside WSL:

```bash
nextflow -version
docker info
aws configure
aws sts get-caller-identity
```

The AWS identity must be able to read the input bucket and write the results
bucket.

## Run Locally In WSL With S3 Results

The sample sheet can be local or on S3. The `reads_r1` and `reads_r2` columns
may point to S3 FASTQ files.

```bash
bash scripts/run_local_wsl_s3.sh \
  --input s3://nf-pipeline-data/Data/PRJNA647806/sample_sheet.csv \
  --outdir s3://nf-pipeline-data/Data/PRJNA647806/results \
  --workdir /tmp/nxf-work \
  --region ap-south-1
```

The local work directory is still local because the local executor needs a
filesystem workspace for Docker tasks. Keep it on the WSL Linux filesystem
rather than under `/mnt/c/...` for better performance.

Resume a run with the same command. The launcher passes `-resume` by default.
Add `--no-resume` only when you intentionally want a fresh run.

## If The Problem Is RAM

For full metagenome assembly, use AWS Batch with S3 work storage:

```bash
bash scripts/run_awsbatch_instant.sh
```

Or pass custom paths:

```bash
bash scripts/run_awsbatch.sh \
  --input s3://my-bucket/project/sample_sheet.csv \
  --queue rhizo-spot-queue \
  --bucket-dir s3://my-bucket/nxf-work \
  --region ap-south-1 \
  --outdir s3://my-bucket/project/results \
  --spot \
  --fusion
```

In that mode, S3 stores inputs, outputs, and the remote Nextflow work
directory, while AWS Batch provides the memory for heavy assembly tasks.
