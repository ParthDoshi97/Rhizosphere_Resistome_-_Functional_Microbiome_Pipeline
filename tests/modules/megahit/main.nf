nextflow.enable.dsl = 2

include { ASSEMBLY_WF } from '../../../subworkflows/local/assembly'

params.outdir     = params.outdir     ?: 'results'
params.test_reads = params.test_reads ?: 'test_data/reads'

def expected_samples = ['MAIZE_RHZ_1', 'MAIZE_RHZ_2', 'MAIZE_BULK_1', 'MAIZE_BULK_2']

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
    def meta = [
        id        : sample_id,
        site      : sample_id.contains('_RHZ_') ? 'rhizosphere' : 'bulk_soil',
        timepoint : 'unknown',
        replicate : replicate,
        batch     : 'PRJNA647806',
        exp_depth : 0.0
    ]

    tuple(meta, reads_r1, reads_r2)
}

workflow {
    Channel
        .fromList(expected_samples.collect { reads_for_sample(it) })
        .set { ch_reads }

    ASSEMBLY_WF(ch_reads)

    // Assert all samples produce non-empty contigs
    ASSEMBLY_WF.out.contigs_pass
        .map { meta, contigs, report ->
            assert file_size(contigs) > 0 : "Contigs file is empty for ${meta.id}"
            tuple(meta, contigs)
        }
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() :
                "Expected all ${expected_samples.size()} samples to pass ASSEMBLY_QC, got ${rows.size()}"
            ''
        }

    // Assert no samples fail assembly QC
    ASSEMBLY_WF.out.contigs_fail
        .collect()
        .view { rows ->
            assert rows.isEmpty() : "Expected no assembly QC failures, got ${rows.size()}"
            ''
        }

    // Assert all samples produce non-empty Plass proteins
    ASSEMBLY_WF.out.proteins
        .map { meta, faa ->
            assert file_size(faa) > 0 : "Plass proteins file is empty for ${meta.id}"
            tuple(meta, faa)
        }
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() :
                "Expected ${expected_samples.size()} Plass protein files, got ${rows.size()}"
            ''
        }

    // Assert MEGAHIT logs contain ALL DONE
    ASSEMBLY_WF.out.megahit_log
        .map { meta, log ->
            def content = log.text
            assert content.contains('ALL DONE') : "MEGAHIT log does not contain 'ALL DONE' for ${meta.id}"
            tuple(meta, log)
        }
        .collect()

    // Assert Plass logs contain no ERROR lines
    ASSEMBLY_WF.out.plass_log
        .map { meta, log ->
            def errors = log.readLines().findAll { it.contains('ERROR') }
            assert errors.isEmpty() : "Plass log contains ERROR lines for ${meta.id}: ${errors}"
            tuple(meta, log)
        }
        .collect()

    // Print per-sample assembly stats table
    ASSEMBLY_WF.out.assembly_stats
        .map { meta, tsv ->
            def rows = tsv.readLines().findAll { !it.startsWith('sample_id') }
            def fields = rows ? rows[0].split('\t') : []
            [fields[0], fields[2], fields[3], fields[6], 'N/A', fields[10]].join(',')
        }
        .collect()
        .view { rows ->
            (['sample_id,total_bases_mbp,n50,contigs_over_1kb,plass_proteins,pass/fail'] + rows.sort()).join('\n')
        }
}

workflow.onComplete {
    def outdir      = new File(params.outdir as String)
    def megahit_dir = new File(outdir, 'assembly/megahit')
    def plass_dir   = new File(outdir, 'assembly/plass')

    assert megahit_dir.exists() : 'Missing results/assembly/megahit/'
    assert plass_dir.exists()   : 'Missing results/assembly/plass/'

    expected_samples.each { sample_id ->
        def contigs = new File(megahit_dir, "${sample_id}.contigs.fa")
        def proteins = new File(plass_dir, "${sample_id}.plass_proteins.faa")
        assert contigs.exists()  : "Missing contigs file for ${sample_id}"
        assert proteins.exists() : "Missing Plass proteins file for ${sample_id}"
    }
}
