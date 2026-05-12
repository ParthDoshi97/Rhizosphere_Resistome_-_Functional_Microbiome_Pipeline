# Rhizosphere Resistome Functional Microbiome Pipeline

Nextflow DSL2 pipeline modules for rhizosphere shotgun metagenome QC and downstream resistome analysis.

Current implemented stage:

- Stage 2 fastp QC, hard QC gating, and MultiQC reporting.

Run locally or on AWS Batch from the top-level `main.nf` with a CSV sample sheet:

```bash
nextflow run main.nf --input samples.csv
```

AWS Batch, S3 work storage, Spot queues, and resume launchers are documented in `docs/aws_batch.md`.
