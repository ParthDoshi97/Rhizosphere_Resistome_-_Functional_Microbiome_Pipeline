# Usage

## Basic command

```bash
nextflow run main.nf \
  --input samples.csv \
  --outdir results \
  -profile docker
```

## Samplesheet

Required columns can use any of these aliases:

| Logical field | Accepted columns |
| --- | --- |
| sample ID | `sample`, `sample_id`, `id` |
| R1 reads | `reads_r1`, `r1`, `fastq_1` |
| R2 reads | `reads_r2`, `r2`, `fastq_2` |

Optional metadata columns:

| Column | Purpose |
| --- | --- |
| `site` | Rhizosphere, bulk soil, or other site/group label. |
| `timepoint` | Timepoint label. |
| `replicate` | Replicate label. |
| `batch` | Batch/group ID used for merged CoverM coverage files. Blank values use `default`. |
| `exp_depth` | Expected depth in Gbp for the fastp depth gate. Use `0` to disable this check. |

For multi-lane samples, put all R1 files in `reads_r1` and all R2 files in `reads_r2`, separated by semicolons or quoted commas:

```csv
sample,reads_r1,reads_r2,site,timepoint,replicate,batch,exp_depth
S1,S1_L001_R1.fastq.gz;S1_L002_R1.fastq.gz,S1_L001_R2.fastq.gz;S1_L002_R2.fastq.gz,rhizosphere,T0,1,batch1,0
```

The validator normalizes aliases, checks duplicate sample IDs, validates lane counts, checks FASTQ extensions, checks numeric `exp_depth`, and writes `samplesheet.valid.csv` plus `samplesheet.validation.json`.

## Main Profiles

| Profile | Purpose |
| --- | --- |
| `docker` | Local or workstation execution with Docker containers. |
| `local` | Conservative WSL/local profile with Docker and low concurrency. |
| `local_s3` | WSL/local execution with S3 input/output and local work storage. |
| `singularity` | HPC-style execution with Singularity. |
| `apptainer` | HPC-style execution with Apptainer. |
| `conda` | Fallback dependency mode. Containers are preferred for production. |
| `awsbatch` | AWS Batch execution with S3 work storage. |
| `awsbatch_spot` | AWS Batch Spot execution with reclaim retries. |
| `awsbatch_fusion` | AWS Batch with Wave and Fusion. |
| `awsbatch_spot_fusion` | AWS Batch Spot with Wave and Fusion. |
| `test` | Small smoke-test settings and relaxed QC thresholds. |
| `test_full` | Project sample sheet with normal QC thresholds. |

Profiles can be combined:

```bash
nextflow run main.nf --input samples.csv --outdir results -profile test,docker
```

## Common Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `--input` | `null` | Input samplesheet CSV. Required unless a profile sets it. |
| `--outdir` | `results` | Output directory or cloud prefix. |
| `--publish_dir_mode` | `copy` | Nextflow publish mode. |
| `--save_logs` | `true` | Publish tool logs. |
| `--save_trimmed` | `false` | Publish fastp-trimmed FASTQs. |
| `--save_bam` | `false` | Publish CoverM BAM and BAI files. |
| `--skip_multiqc` | `false` | Skip MultiQC. |
| `--skip_plass` | `false` | Skip Plass protein assembly. |
| `--fastp_extra_args` | empty | Extra fastp CLI arguments. |
| `--megahit_extra_args` | empty | Extra MEGAHIT CLI arguments. |
| `--plass_extra_args` | empty | Extra Plass CLI arguments. |
| `--coverm_extra_args` | empty | Extra CoverM CLI arguments. |

## QC Thresholds

fastp gate:

| Parameter | Default |
| --- | --- |
| `--fastp_min_reads` | `500000` |
| `--fastp_min_bases_gbp` | `0.5` |
| `--fastp_min_q30_rate` | `0.70` |
| `--fastp_max_dup_rate` | `0.40` |
| `--fastp_min_gc` | `0.40` |
| `--fastp_max_gc` | `0.75` |
| `--fastp_depth_fraction` | `0.30` |

Assembly gate:

| Parameter | Default |
| --- | --- |
| `--megahit_min_contig_len` | `1000` |
| `--assembly_min_bases_mbp` | `50` |
| `--assembly_min_n50_bp` | `1000` |
| `--assembly_min_contigs_1kb` | `5000` |
| `--assembly_max_contigs` | `2000000` |

CoverM:

| Parameter | Default |
| --- | --- |
| `--coverm_min_identity` | `0.95` |
| `--coverm_min_aligned_len` | `50` |
