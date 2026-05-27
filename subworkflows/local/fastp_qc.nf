nextflow.enable.dsl = 2

include { FASTP         } from '../../modules/local/fastp/main'
include { FASTP_QC_GATE } from '../../modules/local/fastp/gate'
include { MULTIQC       } from '../../modules/local/multiqc/main'

workflow FASTP_QC_WF {
    take:
    ch_raw_reads

    main:
    FASTP(ch_raw_reads)
    FASTP_QC_GATE(FASTP.out.json)

    if (!params.skip_multiqc) {
        ch_multiqc_files = Channel.empty()
            .mix(FASTP.out.json.map         { meta, json         -> json })
            .mix(FASTP_QC_GATE.out.pass.map { meta, json, report -> report })
            .mix(FASTP_QC_GATE.out.fail.map { meta, json, report -> report })
            .collect()

        MULTIQC(
            ch_multiqc_files,
            file("${projectDir}/assets/multiqc_config.yaml"),
            file("${projectDir}/assets/multiqc_fail_samples.list", checkIfExists: false)
        )

        ch_multiqc_report = MULTIQC.out.report
        ch_multiqc_data = MULTIQC.out.data
        ch_versions = FASTP.out.versions.mix(FASTP_QC_GATE.out.versions).mix(MULTIQC.out.versions)
    } else {
        ch_multiqc_report = Channel.empty()
        ch_multiqc_data = Channel.empty()
        ch_versions = FASTP.out.versions.mix(FASTP_QC_GATE.out.versions)
    }

    emit:
    reads_pass     = FASTP.out.reads.join(FASTP_QC_GATE.out.pass, by: 0)
    reads_fail     = FASTP.out.reads.join(FASTP_QC_GATE.out.fail,  by: 0)
    json           = FASTP.out.json
    html           = FASTP.out.html
    multiqc_report = ch_multiqc_report
    multiqc_data   = ch_multiqc_data
    versions       = ch_versions
}
