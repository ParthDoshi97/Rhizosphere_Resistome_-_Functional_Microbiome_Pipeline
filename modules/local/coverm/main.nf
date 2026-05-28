nextflow.enable.dsl = 2

process COVERM_CONTIG {
    tag "$meta.id"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container 'quay.io/biocontainers/coverm:0.7.0--hcb7b614_4'

    input:
    tuple val(meta), path(contigs), path(reads_r1), path(reads_r2)

    output:
    tuple val(meta), path("${meta.id}_coverage.tsv"),          emit: coverage
    tuple val(meta), path("${meta.id}_bam/${meta.id}.bam"),     emit: bam
    tuple val(meta), path("${meta.id}_bam/${meta.id}.bam.bai"), emit: bai
    tuple val(meta), path("${meta.id}.coverm.log"),             emit: coverm_log
    path "versions.yml",                                        emit: versions

    script:
    def r1_inputs = reads_r1 instanceof List ? reads_r1.collect { it.name }.join(' ') : reads_r1.name
    def r2_inputs = reads_r2 instanceof List ? reads_r2.collect { it.name }.join(' ') : reads_r2.name
    def args = task.ext.args ?: ''

    """
set -euo pipefail

mkdir -p ${meta.id}_bam

R1_FILES="${r1_inputs}"
R2_FILES="${r2_inputs}"

coverm contig \\
    --coupled \${R1_FILES} \${R2_FILES} \\
    --reference ${contigs} \\
    --mapper strobealign \\
    --methods metabat mean covered_fraction \\
    --threads ${task.cpus} \\
    --min-read-percent-identity ${params.coverm_min_identity} \\
    --min-read-aligned-length ${params.coverm_min_aligned_len} \\
    --proper-pairs-only \\
    ${args} \\
    --output-file ${meta.id}_coverage.tsv \\
    --bam-file-cache-directory ${meta.id}_bam/ \\
    2>&1 | tee ${meta.id}.coverm.log

if [ ! -f ${meta.id}_bam/${meta.id}.bam ]; then
    BAM_FILE=\$(find ${meta.id}_bam -maxdepth 1 -type f -name '*.bam' | head -1)
    if [ -z "\${BAM_FILE}" ]; then
        echo "ERROR: CoverM did not produce a BAM file in ${meta.id}_bam" >&2
        exit 1
    fi
    mv "\${BAM_FILE}" ${meta.id}_bam/${meta.id}.bam
fi

samtools index \\
    -@ ${task.cpus} \\
    ${meta.id}_bam/${meta.id}.bam

cat <<-END_VERSIONS > versions.yml
"${task.process}":
    coverm: \$(coverm --version 2>&1 | head -1 | sed 's/coverm //')
    strobealign: \$(strobealign --version 2>&1 | head -1)
    samtools: \$(samtools --version | head -1 | sed 's/samtools //')
END_VERSIONS
    """
}
