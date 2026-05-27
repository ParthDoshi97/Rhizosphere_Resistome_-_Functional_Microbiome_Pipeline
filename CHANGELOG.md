# Changelog

## Unreleased

- Added production-oriented samplesheet validation and normalization.
- Added `nextflow_schema.json` for parameter documentation.
- Moved the top-level workflow into `workflows/rhizosphere/main.nf`.
- Added centralized module configuration under `conf/modules/`.
- Added default execution trace, report, timeline, DAG, and software versions output.
- Added Docker, Singularity, Apptainer, Conda, `test`, and `test_full` profiles.
- Added skip/save flags for MultiQC, Plass, trimmed FASTQs, logs, and CoverM BAMs.
- Aligned MEGAHIT and Plass published output paths with module test expectations.
