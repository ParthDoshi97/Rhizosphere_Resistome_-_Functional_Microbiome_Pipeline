nextflow.enable.dsl = 2

process MULTIQC {
    label 'process_single'

    container 'quay.io/biocontainers/multiqc:1.21--pyhdfd78af_0'

    publishDir "${params.outdir}/multiqc", mode: 'copy'

    input:
    path collected_files
    path multiqc_config
    path fail_sample_list

    output:
    path "multiqc_report.html", emit: report
    path "multiqc_report_data/", emit: data
    path "versions.yml",        emit: versions
    path "failed_samples.txt",  emit: failed_samples

    script:
    """
find . -name "*.qc_fail.txt" -exec basename {} .qc_fail.txt \\; | sort > failed_samples.txt || true

multiqc \\
    --config ${multiqc_config} \\
    --filename multiqc_report.html \\
    --force \\
    --dirs \\
    . \\
    2>&1 | tee multiqc.log

cat > versions.yml <<END_VERSIONS
"${task.process}":
    multiqc: \$(multiqc --version 2>&1 | sed 's/multiqc, version //')
END_VERSIONS
    """
}
