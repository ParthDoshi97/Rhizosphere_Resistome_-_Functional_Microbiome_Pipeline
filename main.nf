nextflow.enable.dsl = 2

include { RHIZOSPHERE_RESISTOME_WF } from './workflows/rhizosphere/main'

workflow {
    if (!params.input) {
        error "Missing required --input sample sheet"
    }

    Channel
        .fromPath(params.input, checkIfExists: true)
        .set { ch_sample_sheet }

    RHIZOSPHERE_RESISTOME_WF(ch_sample_sheet)
}
