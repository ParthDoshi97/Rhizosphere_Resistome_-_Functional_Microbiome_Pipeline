nextflow.enable.dsl = 2

process PLASS {
    label 'process_high_memory'

    container 'quay.io/biocontainers/plass:5.cf8933301-2'

    publishDir [
        path: "${params.outdir}/assembly/plass",
        mode: 'copy',
        pattern: "*.plass_proteins.faa"
    ],
    [
        path: "${params.outdir}/assembly/plass/logs",
        mode: 'copy',
        pattern: "*.plass.log"
    ]

    input:
    tuple val(meta), path(reads_r1), path(reads_r2)

    output:
    tuple val(meta), path("${meta.id}.plass_proteins.faa"), emit: proteins
    tuple val(meta), path("${meta.id}.plass.log"),          emit: log
    path "versions.yml",                                    emit: versions

    script:
    """
# Handle multi-lane: concatenate if needed
if [ \$(echo "${reads_r1}" | wc -w) -gt 1 ]; then
    cat ${reads_r1} > merged_R1.fastq.gz
    cat ${reads_r2} > merged_R2.fastq.gz
    INPUT_R1="merged_R1.fastq.gz"
    INPUT_R2="merged_R2.fastq.gz"
else
    INPUT_R1="${reads_r1}"
    INPUT_R2="${reads_r2}"
fi

plass assemble \\
    \${INPUT_R1} \\
    \${INPUT_R2} \\
    ${meta.id}.plass_proteins.faa \\
    tmp_${meta.id} \\
    --threads ${task.cpus} \\
    --min-length ${params.plass_min_protein_len} \\
    --translation-table 11 \\
    2>&1 | tee ${meta.id}.plass.log

rm -rf tmp_${meta.id}

cat <<-END_VERSIONS > versions.yml
"${task.process}":
    plass: \$(plass version 2>&1 | head -1)
END_VERSIONS
    """
}
