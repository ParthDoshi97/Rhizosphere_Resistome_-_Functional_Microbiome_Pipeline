nextflow.enable.dsl = 2

include { COVERM_CONTIG      } from '../../modules/local/coverm/main'
include { COVERM_BATCH_MERGE } from '../../modules/local/coverm/merge'

workflow COVERM_WF {
    take:
    ch_contigs_reads

    main:
    COVERM_CONTIG(ch_contigs_reads)

    ch_batch_coverage = COVERM_CONTIG.out.coverage
        .map { meta, tsv -> tuple(meta.batch ?: 'default', tsv) }
        .groupTuple(by: 0)

    ch_batch_bam = COVERM_CONTIG.out.bam
        .map { meta, bam -> tuple(meta.batch ?: 'default', bam) }
        .groupTuple(by: 0)

    ch_batch_bai = COVERM_CONTIG.out.bai
        .map { meta, bai -> tuple(meta.batch ?: 'default', bai) }
        .groupTuple(by: 0)

    COVERM_BATCH_MERGE(
        ch_batch_coverage,
        file("${projectDir}/bin/merge_coverm_metabat.py")
    )

    emit:
    coverage_per_sample = COVERM_CONTIG.out.coverage
    bam                 = COVERM_CONTIG.out.bam
    bai                 = COVERM_CONTIG.out.bai
    coverm_log          = COVERM_CONTIG.out.coverm_log
    merged_coverage     = COVERM_BATCH_MERGE.out.merged_coverage
    batch_bams          = ch_batch_bam
    batch_bais          = ch_batch_bai
    versions            = COVERM_CONTIG.out.versions.mix(COVERM_BATCH_MERGE.out.versions)
}
