nextflow.enable.dsl = 2

process COVERM_BATCH_MERGE {
    label 'process_single'

    container 'python:3.11'

    publishDir "${params.outdir}/coverage/merged", mode: 'copy'

    input:
    tuple val(batch_id), path(coverage_tsvs)

    output:
    tuple val(batch_id), path("${batch_id}_merged_coverage.tsv"), emit: merged_coverage

    script:
    """
python3 ${projectDir}/bin/merge_coverm_metabat.py \\
    ${coverage_tsvs} \\
    > ${batch_id}_merged_coverage.tsv
    """
}
