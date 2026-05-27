# Output

The pipeline publishes final outputs under `--outdir`.

```text
results/
  pipeline_info/
    samplesheet.valid.csv
    samplesheet.validation.json
    software_versions.yml
    execution_trace.txt
    execution_report.html
    execution_timeline.html
    pipeline_dag.html
  fastp/
    *.fastp.json
    *.fastp.html
    qc/
      *.qc_pass.txt
      *.qc_fail.txt
    logs/
      *.fastp.stderr
    trimmed/
      *.fastp.fastq.gz
  assembly/
    megahit/
      <sample>.contigs.fa
      logs/
        <sample>.megahit.log
      qc/
        *.assembly_stats.tsv
        *.assembly_pass.txt
        *.assembly_fail.txt
    plass/
      <sample>.plass_proteins.faa
      logs/
        <sample>.plass.log
  coverage/
    *_coverage.tsv
    merged/
      *_merged_coverage.tsv
    logs/
      *.coverm.log
    bam/
      *.bam
      *.bam.bai
  multiqc/
    multiqc_report.html
    multiqc_report_data/
    failed_samples.txt
```

`fastp/trimmed/` is published only with `--save_trimmed true`.

`coverage/bam/` is published only with `--save_bam true`.

Tool logs are published when `--save_logs true`.

## Pipeline Info

`pipeline_info/` contains run-level metadata for production debugging and auditing:

| File | Purpose |
| --- | --- |
| `samplesheet.valid.csv` | Normalized samplesheet used by the workflow. |
| `samplesheet.validation.json` | Validator status, warnings, and errors. |
| `software_versions.yml` | Tool versions emitted by pipeline processes. |
| `execution_trace.txt` | Per-task resource and status trace. |
| `execution_report.html` | Interactive execution report. |
| `execution_timeline.html` | Per-task execution timeline. |
| `pipeline_dag.html` | Workflow DAG. |
