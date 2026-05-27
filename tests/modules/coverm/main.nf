nextflow.enable.dsl = 2

include { FASTP_QC_WF } from '../../../subworkflows/local/fastp_qc'
include { ASSEMBLY_WF } from '../../../subworkflows/local/assembly'
include { COVERM_WF   } from '../../../subworkflows/local/coverm'

params.outdir     = params.outdir     ?: 'results'
params.test_reads = params.test_reads ?: 'test_data/reads'

def expected_samples = ['MAIZE_RHZ_1', 'MAIZE_RHZ_2', 'MAIZE_BULK_1', 'MAIZE_BULK_2']
def expected_batches = [
    batch_rhz : 2,
    batch_bulk: 2
]

def file_size = { path ->
    path instanceof java.nio.file.Path ? java.nio.file.Files.size(path) : path.length()
}

def reads_for_sample = { sample_id ->
    def sample_dir = file("${params.test_reads}/${sample_id}", checkIfExists: true)
    def fastqs = sample_dir.listFiles()
        .findAll { it.name ==~ /(?i).*\.(fastq|fq)\.gz$/ }
        .sort { it.name }

    def reads_r1 = fastqs.findAll {
        it.name ==~ /(?i).*(^|[._-])R1([._-]|$).*\.(fastq|fq)\.gz$/ ||
        it.name ==~ /(?i).*_1\.(fastq|fq)\.gz$/
    }
    def reads_r2 = fastqs.findAll {
        it.name ==~ /(?i).*(^|[._-])R2([._-]|$).*\.(fastq|fq)\.gz$/ ||
        it.name ==~ /(?i).*_2\.(fastq|fq)\.gz$/
    }

    assert reads_r1 : "No R1 FASTQ files found for ${sample_id}"
    assert reads_r2 : "No R2 FASTQ files found for ${sample_id}"
    assert reads_r1.size() == reads_r2.size() : "Mismatched R1/R2 lane count for ${sample_id}"

    def replicate = sample_id.tokenize('_').last()
    def batch = sample_id.contains('_RHZ_') ? 'batch_rhz' : 'batch_bulk'
    def meta = [
        id        : sample_id,
        site      : sample_id.contains('_RHZ_') ? 'rhizosphere' : 'bulk_soil',
        timepoint : 'unknown',
        replicate : replicate,
        batch     : batch,
        exp_depth : 0.0
    ]

    tuple(meta, reads_r1, reads_r2)
}

process BAM_QUICKCHECK {
    container 'quay.io/biocontainers/samtools:1.20--h50ea8bc_1'

    input:
    tuple val(meta), path(bam)

    output:
    tuple val(meta), path("${meta.id}.quickcheck.txt")

    script:
    """
samtools quickcheck ${bam}
touch ${meta.id}.quickcheck.txt
    """
}

workflow {
    Channel
        .fromList(expected_samples.collect { reads_for_sample(it) })
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
    BAM_QUICKCHECK(COVERM_WF.out.bam)

    COVERM_WF.out.coverage_per_sample
        .map { meta, coverage ->
            assert file_size(coverage) > 0 : "Coverage TSV is empty for ${meta.id}"
            def rows = coverage.readLines().findAll { it.trim() && !it.startsWith('contigName') }
            def header = coverage.readLines().first().split('\t')
            def mean_idx = header.findIndexOf { it.toLowerCase().contains('mean') }
            def covered_idx = header.findIndexOf { it.toLowerCase().contains('covered') }
            def first = rows ? rows.first().split('\t') : []
            [
                meta.id,
                rows.size(),
                mean_idx >= 0 && first.size() > mean_idx ? first[mean_idx] : 'NA',
                covered_idx >= 0 && first.size() > covered_idx ? first[covered_idx] : 'NA'
            ].join(',')
        }
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() : "Expected ${expected_samples.size()} coverage TSVs, got ${rows.size()}"
            (['sample_id,contig_count,mean_depth,covered_fraction'] + rows.sort()).join('\n')
        }

    COVERM_WF.out.bam
        .map { meta, bam ->
            assert file_size(bam) > 0 : "BAM is empty for ${meta.id}"
            tuple(meta, bam)
        }
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() : "Expected ${expected_samples.size()} BAMs, got ${rows.size()}"
            ''
        }

    COVERM_WF.out.bai
        .map { meta, bai ->
            assert file_size(bai) > 0 : "BAI is empty for ${meta.id}"
            tuple(meta, bai)
        }
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() : "Expected ${expected_samples.size()} BAI files, got ${rows.size()}"
            ''
        }

    BAM_QUICKCHECK.out
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() : "Expected ${expected_samples.size()} BAM quickchecks, got ${rows.size()}"
            ''
        }

    COVERM_WF.out.merged_coverage
        .map { batch_id, merged ->
            assert file_size(merged) > 0 : "Merged coverage TSV is empty for ${batch_id}"
            def columns = merged.readLines().first().split('\t').size()
            def expected_columns = 3 + (2 * expected_batches[batch_id])
            assert columns == expected_columns :
                "Expected ${expected_columns} merged columns for ${batch_id}, got ${columns}"
            tuple(batch_id, merged)
        }
        .collect()
        .view { rows ->
            assert rows.size() == expected_batches.size() : "Expected ${expected_batches.size()} merged batch TSVs, got ${rows.size()}"
            ''
        }
}
