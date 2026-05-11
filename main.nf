nextflow.enable.dsl = 2

include { FASTP_QC_WF } from './subworkflows/local/fastp_qc'

params.input = null

def requireField = { row, names ->
    for (name in names) {
        def value = row[name]
        if (value != null && value.toString().trim()) {
            return value.toString().trim()
        }
    }
    error "Sample sheet is missing required column. Expected one of: ${names.join(', ')}"
}

def readList = { value ->
    value.toString()
        .split(/[;,]/)
        .collect { it.trim() }
        .findAll { it }
        .collect { file(it, checkIfExists: true) }
}

workflow {
    if (!params.input) {
        error "Missing required --input sample sheet"
    }

    Channel
        .fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true)
        .map { row ->
            def sample_id = requireField(row, ['id', 'sample_id', 'sample'])
            def r1_value = requireField(row, ['reads_r1', 'r1', 'fastq_1'])
            def r2_value = requireField(row, ['reads_r2', 'r2', 'fastq_2'])

            def meta = [
                id        : sample_id,
                site      : (row.site ?: '').toString(),
                timepoint : (row.timepoint ?: '').toString(),
                replicate : (row.replicate ?: '').toString(),
                batch     : (row.batch ?: '').toString(),
                exp_depth : (row.exp_depth ?: 0) as BigDecimal
            ]

            tuple(meta, readList(r1_value), readList(r2_value))
        }
        .set { ch_raw_reads }

    FASTP_QC_WF(ch_raw_reads)
}
