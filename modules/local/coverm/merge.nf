nextflow.enable.dsl = 2

process COVERM_BATCH_MERGE {
    tag "$batch_id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container 'python:3.11'

    input:
    tuple val(batch_id), path(coverage_tsvs)
    path merge_script

    output:
    tuple val(batch_id), path("${batch_id}_merged_coverage.tsv"), emit: merged_coverage
    path "versions.yml", emit: versions

    script:
    """
set -euo pipefail

python3 ${merge_script} \\
    ${coverage_tsvs} \\
    > ${batch_id}_merged_coverage.tsv

cat > versions.yml <<END_VERSIONS
"${task.process}":
    python: \$(python3 --version | sed 's/Python //')
END_VERSIONS
    """
}
