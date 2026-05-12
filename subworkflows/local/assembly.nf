nextflow.enable.dsl = 2

include { MEGAHIT     } from '../../modules/local/megahit/main'
include { ASSEMBLY_QC } from '../../modules/local/megahit/assembly_qc'
include { PLASS       } from '../../modules/local/plass/main'

workflow ASSEMBLY_WF {
    take:
    ch_reads  // tuple val(meta), path(r1_list), path(r2_list)

    main:
    // Both assembly processes launch simultaneously from the same channel.
    // Neither waits for the other — they are completely independent.
    MEGAHIT(ch_reads)
    PLASS(ch_reads)

    // Apply post-assembly QC gate to MEGAHIT contigs only.
    // Plass proteins are not gated — partial protein catalogs are
    // still useful for DRAM even if the nucleotide assembly is poor.
    ASSEMBLY_QC(MEGAHIT.out.contigs)

    emit:
    contigs_pass   = ASSEMBLY_QC.out.pass
    contigs_fail   = ASSEMBLY_QC.out.fail
    assembly_stats = ASSEMBLY_QC.out.stats
    proteins       = PLASS.out.proteins
    megahit_log    = MEGAHIT.out.log
    plass_log      = PLASS.out.log
    versions       = MEGAHIT.out.versions.mix(PLASS.out.versions)
}
