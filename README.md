# Rhizosphere Resistome Functional Microbiome Pipeline

Nextflow DSL2 pipeline for rhizosphere shotgun metagenome QC, assembly, protein assembly, and contig coverage profiling.

Implemented stages:

- Samplesheet validation and normalization.
- fastp read QC, trimming, hard QC gating, and MultiQC reporting.
- MEGAHIT nucleotide assembly with assembly QC.
- Optional Plass protein assembly.
- CoverM contig coverage profiling for SemiBin2-style abundance inputs.
- Pipeline metadata: execution trace, timeline, report, DAG, validation report, and software versions.

Run from the top-level `main.nf` with a CSV samplesheet:

```bash
nextflow run main.nf --input samples.csv --outdir results -profile docker
```

See `docs/usage.md` for parameters and profiles, `docs/output.md` for the results layout, `docs/wsl_s3.md` for WSL + S3 runs, `docs/aws_batch.md` for AWS Batch, and `docs/data_download.md` for SRA/BioProject download helpers.
