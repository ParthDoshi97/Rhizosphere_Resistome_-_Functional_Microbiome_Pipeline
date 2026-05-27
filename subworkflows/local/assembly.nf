nextflow.enable.dsl = 2

include { MEGAHIT     } from '../../modules/local/megahit/main'
include { ASSEMBLY_QC } from '../../modules/local/megahit/assembly_qc'
include { PLASS       } from '../../modules/local/plass/main'

workflow ASSEMBLY_WF {
    take:
    ch_reads  // tuple val(meta), path(r1_list), path(r2_list)

    main:
    // MEGAHIT is the required nucleotide assembly route.
    MEGAHIT(ch_reads)

    // Apply post-assembly QC gate to MEGAHIT contigs only.
    ASSEMBLY_QC(MEGAHIT.out.contigs)

    if (!params.skip_plass) {
        PLASS(ch_reads)
        ch_proteins = PLASS.out.proteins
        ch_plass_log = PLASS.out.log
        ch_versions = MEGAHIT.out.versions.mix(ASSEMBLY_QC.out.versions).mix(PLASS.out.versions)
    } else {
        ch_proteins = Channel.empty()
        ch_plass_log = Channel.empty()
        ch_versions = MEGAHIT.out.versions.mix(ASSEMBLY_QC.out.versions)
    }

    emit:
    contigs_pass   = ASSEMBLY_QC.out.pass
    contigs_fail   = ASSEMBLY_QC.out.fail
    assembly_stats = ASSEMBLY_QC.out.stats
    proteins       = ch_proteins
    megahit_log    = MEGAHIT.out.log
    plass_log      = ch_plass_log
    versions       = ch_versions
}
