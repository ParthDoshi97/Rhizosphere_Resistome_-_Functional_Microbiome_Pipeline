nextflow.enable.dsl = 2

process FASTP {
    label 'process_medium'

    container 'quay.io/biocontainers/fastp:0.23.4--h5f740d0_0'

    publishDir "${params.outdir}/fastp/logs", mode: 'copy', pattern: '*.fastp.stderr'

    input:
    tuple val(meta), path(reads_r1), path(reads_r2)

    output:
    tuple val(meta), path("${meta.id}_R1.fastp.fastq.gz"), path("${meta.id}_R2.fastp.fastq.gz"), emit: reads
    tuple val(meta), path("${meta.id}.fastp.json"),                                               emit: json
    tuple val(meta), path("${meta.id}.fastp.html"),                                               emit: html
    path "versions.yml",                                                                          emit: versions

    script:
    def r1_inputs = reads_r1 instanceof List ? reads_r1.collect { it.name }.join(',') : reads_r1.name
    def r2_inputs = reads_r2 instanceof List ? reads_r2.collect { it.name }.join(',') : reads_r2.name

    """
fastp \\
    --in1 '${r1_inputs}' \\
    --in2 '${r2_inputs}' \\
    --out1 '${meta.id}_R1.fastp.fastq.gz' \\
    --out2 '${meta.id}_R2.fastp.fastq.gz' \\
    --json '${meta.id}.fastp.json' \\
    --html '${meta.id}.fastp.html' \\
    --thread ${task.cpus} \\
    --detect_adapter_for_pe \\
    --qualified_quality_phred 20 \\
    --unqualified_percent_limit 40 \\
    --length_required 50 \\
    --low_complexity_filter \\
    --complexity_threshold 30 \\
    --correction \\
    --overlap_diff_percent_limit 10 \\
    2> '${meta.id}.fastp.stderr'

cat > versions.yml <<END_VERSIONS
"${task.process}":
    fastp: \$(fastp --version 2>&1 | sed 's/fastp //')
END_VERSIONS
    """
}
