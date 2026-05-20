# Data Download With sracha

This repository includes `scripts/download_sra_sracha.sh`, a portable wrapper
around [`sracha`](https://github.com/rnabioco/sracha-rs) for downloading SRA
data in WSL, Linux, macOS, or Git Bash.

`sracha` accepts:

- Run accessions: `SRR`, `ERR`, `DRR`
- Study accessions: `SRP`, `ERP`, `DRP`
- BioProject accessions: `PRJNA`, `PRJEB`, `PRJDB`
- Accession-list files with one accession per line
- CSV/TSV sample sheets with an accession column

By default the wrapper uses `sracha get`, which downloads, converts to FASTQ,
and writes gzip-compressed FASTQ files.

## Install sracha

If `sracha` is not already installed:

```bash
bash scripts/download_sra_sracha.sh --install SRR28588231 --dry-run
```

That tries to install with `cargo`. You can also install manually:

```bash
cargo install --git https://github.com/rnabioco/sracha-rs sracha
```

Or use a package manager:

```bash
pixi add --channel bioconda sracha
conda install -c bioconda sracha
```

## Download One Run

```bash
bash scripts/download_sra_sracha.sh SRR28588231 \
  --output-dir data/sra_downloads
```

## Download a BioProject

Always do a dry run first for large projects:

```bash
bash scripts/download_sra_sracha.sh PRJNA647806 \
  --output-dir data/PRJNA647806/reads \
  --prefer-ena \
  --dry-run
```

Then download:

```bash
bash scripts/download_sra_sracha.sh PRJNA647806 \
  --output-dir data/PRJNA647806/reads \
  --prefer-ena \
  --folder-per-accession \
  --write-sample-sheet data/PRJNA647806/sample_sheet.csv \
  --sample-batch PRJNA647806
```

## Download From a Sample Sheet

If your input sheet has one accession per row, give the sheet directly. The
script auto-detects common columns such as `accession`, `run_accession`,
`sra_accession`, `bioproject`, `study`, `id`, `sample_id`, or `sample`.

Example input:

```csv
id,site,timepoint,replicate,batch
SRR12345678,rhizosphere,T0,1,PRJNA000000
SRR12345679,rhizosphere,T0,2,PRJNA000000
```

Download every accession in the `id` column:

```bash
bash scripts/download_sra_sracha.sh \
  --sample-sheet samples.csv \
  --accession-column id \
  --output-dir data/my_project/reads \
  --prefer-ena \
  --folder-per-accession
```

If your sheet has a dedicated accession column:

```csv
sample_id,run_accession,site,timepoint,replicate,batch
MAIZE_RHZ_1,SRR12345678,rhizosphere,T0,1,PRJNA000000
MAIZE_RHZ_2,SRR12345679,rhizosphere,T0,2,PRJNA000000
```

Use that column:

```bash
bash scripts/download_sra_sracha.sh \
  --sample-sheet samples.csv \
  --accession-column run_accession \
  --output-dir data/my_project/reads \
  --prefer-ena \
  --folder-per-accession
```

To also build this pipeline's `reads_r1` / `reads_r2` CSV after download, add
`--write-sample-sheet`:

```bash
bash scripts/download_sra_sracha.sh \
  --sample-sheet samples.csv \
  --accession-column run_accession \
  --output-dir data/my_project/reads \
  --prefer-ena \
  --folder-per-accession \
  --write-sample-sheet data/my_project/sample_sheet.csv \
  --sample-batch my_project
```

The values extracted from the selected column must look like SRA run, study, or
BioProject accessions. If your `id` column contains custom names like
`MAIZE_RHZ_1`, add a real accession column and pass it with
`--accession-column`.

The repository test sheet at `test_data/sample_sheet.csv` already points to S3
FASTQ files in `reads_r1` and `reads_r2`. Its `id` column contains custom sample
names, not SRA run accessions. The only downloadable accession-like value in
that sheet is the repeated BioProject value in `batch`:

```bash
bash scripts/download_sra_sracha.sh \
  --sample-sheet test_data/sample_sheet.csv \
  --accession-column batch \
  --output-dir data/PRJNA647806/reads \
  --prefer-ena \
  --folder-per-accession \
  --dry-run
```

Because `batch` is `PRJNA647806`, this resolves the whole BioProject. To
download only specific runs, add a real per-sample run column such as
`run_accession` to the sheet.

## Download From an Accession List

```bash
bash scripts/download_sra_sracha.sh \
  --accession-list SRR_Acc_List.txt \
  --output-dir data/my_project/reads \
  --folder-per-accession \
  --write-sample-sheet data/my_project/sample_sheet.csv \
  --sample-batch my_project
```

## Download and Upload to S3

When `--s3-prefix` is provided, the script syncs downloaded files to S3. If a
sample sheet is generated, read paths are written using the same S3 prefix so
the file can be used with AWS Batch.

The `--write-sample-sheet` helper is designed for this pipeline's paired-end
input format. Single-end accessions are still downloaded, but they are skipped
from the generated pipeline sample sheet because `main.nf` currently requires
both `reads_r1` and `reads_r2`.

```bash
bash scripts/download_sra_sracha.sh \
  --sample-sheet samples.csv \
  --accession-column run_accession \
  --output-dir data/PRJNA647806/reads \
  --s3-prefix s3://nf-pipeline-data/Data/PRJNA647806/reads \
  --write-sample-sheet data/PRJNA647806/sample_sheet.csv \
  --sample-batch PRJNA647806
```

Upload the generated sample sheet:

```bash
aws s3 cp data/PRJNA647806/sample_sheet.csv \
  s3://nf-pipeline-data/Data/PRJNA647806/sample_sheet.csv
```

## Useful Options

```bash
# Use Illumina-style paired suffixes: _R1/_R2
--paired-suffix r

# Store each run in its own folder
--folder-per-accession

# Keep SRA files after FASTQ conversion
--keep-sra

# Use SRA-lite instead of full-quality SRA
--format sralite

# Use zstd instead of gzip
--zstd

# Disable confirmation prompts for project/large downloads is the default.
# Add --ask if you want sracha to prompt before large downloads.
--ask
```
