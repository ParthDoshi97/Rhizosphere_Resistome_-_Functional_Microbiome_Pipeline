nextflow.enable.dsl = 2

include { VALIDATE_SAMPLESHEET      } from '../../modules/local/samplesheet/validate'
include { PUBLISH_SOFTWARE_VERSIONS } from '../../modules/local/utils/software_versions'
include { FASTP_QC_WF               } from '../../subworkflows/local/fastp_qc'
include { ASSEMBLY_WF               } from '../../subworkflows/local/assembly'
include { COVERM_WF                 } from '../../subworkflows/local/coverm'

def readList(value) {
    value.toString()
        .split(/[;,]/)
        .collect { it.trim() }
        .findAll { it }
        .collect { file(it, checkIfExists: true) }
}

workflow RHIZOSPHERE_RESISTOME_WF {
    take:
    ch_sample_sheet

    main:
    VALIDATE_SAMPLESHEET(
        ch_sample_sheet,
        file("${projectDir}/bin/validate_samplesheet.py")
    )

    VALIDATE_SAMPLESHEET.out.validated_csv
        .splitCsv(header: true)
        .map { row ->
            def meta = [
                id        : row.sample.toString(),
                site      : (row.site ?: '').toString(),
                timepoint : (row.timepoint ?: '').toString(),
                replicate : (row.replicate ?: '').toString(),
                batch     : (row.batch ?: '').toString(),
                exp_depth : (row.exp_depth ?: 0) as BigDecimal
            ]

            tuple(meta, readList(row.reads_r1), readList(row.reads_r2))
        }
        .set { ch_raw_reads }

    FASTP_QC_WF(ch_raw_reads)

    FASTP_QC_WF.out.reads_pass
        .map { meta, reads_r1, reads_r2, json, report ->
            tuple(meta, reads_r1, reads_r2)
        }
        .set { ch_qc_pass_reads }

    ASSEMBLY_WF(ch_qc_pass_reads)

    ASSEMBLY_WF.out.contigs_pass
        .map { meta, contigs, report ->
            tuple(meta, contigs)
        }
        .join(ch_qc_pass_reads, by: 0)
        .map { meta, contigs, reads_r1, reads_r2 ->
            tuple(meta, contigs, reads_r1, reads_r2)
        }
        .set { ch_coverm_input }

    COVERM_WF(ch_coverm_input)

    VALIDATE_SAMPLESHEET.out.versions
        .mix(FASTP_QC_WF.out.versions)
        .mix(ASSEMBLY_WF.out.versions)
        .mix(COVERM_WF.out.versions)
        .collect()
        .set { ch_version_files }

    PUBLISH_SOFTWARE_VERSIONS(ch_version_files)

    emit:
    validated_samplesheet = VALIDATE_SAMPLESHEET.out.validated_csv
    validation_report     = VALIDATE_SAMPLESHEET.out.validation_report
    reads_pass            = FASTP_QC_WF.out.reads_pass
    reads_fail            = FASTP_QC_WF.out.reads_fail
    contigs_pass          = ASSEMBLY_WF.out.contigs_pass
    contigs_fail          = ASSEMBLY_WF.out.contigs_fail
    coverage_per_sample   = COVERM_WF.out.coverage_per_sample
    merged_coverage       = COVERM_WF.out.merged_coverage
    software_versions     = PUBLISH_SOFTWARE_VERSIONS.out.software_versions
}
