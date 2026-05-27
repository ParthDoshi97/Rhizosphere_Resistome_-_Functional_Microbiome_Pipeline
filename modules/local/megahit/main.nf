nextflow.enable.dsl = 2

process MEGAHIT {
    tag "$meta.id"
    label 'process_high'

    conda "${moduleDir}/environment.yml"
    container 'quay.io/biocontainers/megahit:1.2.9--h5b5514e_3'

    input:
    tuple val(meta), path(reads_r1), path(reads_r2)

    output:
    tuple val(meta), path("${meta.id}.contigs.fa"),  emit: contigs
    tuple val(meta), path("${meta.id}/"),            emit: assembly_dir
    tuple val(meta), path("${meta.id}.megahit.log"), emit: log
    path "versions.yml",                             emit: versions

    script:
    def r1_inputs = reads_r1 instanceof List ? reads_r1.collect { it.name }.join(',') : reads_r1.name
    def r2_inputs = reads_r2 instanceof List ? reads_r2.collect { it.name }.join(',') : reads_r2.name
    def args = task.ext.args ?: ''

    """
set -euo pipefail

# Check if a partial assembly exists (Spot resume scenario)
if [ -d "${meta.id}" ] && [ -f "${meta.id}/checkpoints.txt" ]; then
    CONTINUE_FLAG="--continue"
else
    CONTINUE_FLAG=""
fi

megahit \\
    -1 '${r1_inputs}' \\
    -2 '${r2_inputs}' \\
    --presets meta-large \\
    --min-contig-len ${params.megahit_min_contig_len} \\
    --num-cpu-threads ${task.cpus} \\
    --memory ${task.memory.toBytes()} \\
    -o ${meta.id} \\
    ${args} \\
    \${CONTINUE_FLAG} \\
    2>&1 | tee ${meta.id}.megahit.log

# Copy final contigs to a flat output file for downstream use
cp ${meta.id}/final.contigs.fa ${meta.id}.contigs.fa

cat <<-END_VERSIONS > versions.yml
"${task.process}":
    megahit: \$(megahit --version 2>&1 | head -1 | sed 's/MEGAHIT v//')
END_VERSIONS
    """
}
