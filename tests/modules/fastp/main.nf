nextflow.enable.dsl = 2

include { FASTP_QC_WF } from '../../../subworkflows/local/fastp_qc'

params.outdir = params.outdir ?: 'results'
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
        .set { ch_raw_reads }

    FASTP_QC_WF(ch_raw_reads)

    FASTP_QC_WF.out.json
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() : "Expected ${expected_samples.size()} fastp JSON files, observed ${rows.size()}"
            ''
        }

    FASTP_QC_WF.out.reads_pass
        .map { meta, r1, r2, json, report ->
            assert file_size(r1) > 0 : "Trimmed R1 FASTQ is empty for ${meta.id}"
            assert file_size(r2) > 0 : "Trimmed R2 FASTQ is empty for ${meta.id}"
            tuple(meta, r1, r2, json, report)
        }
        .collect()
        .view { rows ->
            assert rows.size() == expected_samples.size() : "Expected all ${expected_samples.size()} samples to pass QC, observed ${rows.size()}"
            ''
        }

    FASTP_QC_WF.out.reads_fail
        .collect()
        .view { rows ->
            assert rows.isEmpty() : "Expected no QC failures, observed ${rows.size()}"
            ''
        }

    FASTP_QC_WF.out.json
        .join(FASTP_QC_WF.out.reads_pass.map { meta, r1, r2, json, report -> tuple(meta, report) }, by: 0)
        .map { meta, json, report ->
            def parsed = new groovy.json.JsonSlurper().parse(json.toFile())
            def before_reads = parsed.summary.before_filtering.total_reads
            def after_reads = parsed.filtering_result.passed_filter_reads
            def q30_rate = parsed.summary.after_filtering.q30_rate
            def gc_content = parsed.summary.after_filtering.gc_content
            [meta.id, before_reads, after_reads, q30_rate, gc_content, report.name.contains('qc_pass') ? 'pass' : 'fail'].join(',')
        }
        .collect()
        .view { rows ->
            (['sample_id,total_reads_before,total_reads_after,q30_rate,gc_content,pass/fail'] + rows.sort()).join('\n')
        }
}

workflow.onComplete {
    def outdir = new File(params.outdir as String)
    def multiqc_dir = new File(outdir, 'multiqc')
    def report = new File(multiqc_dir, 'multiqc_report.html')
    def data_dir = new File(multiqc_dir, 'multiqc_data')
    def fastp_table = new File(data_dir, 'multiqc_fastp.txt')
    def general_stats = new File(data_dir, 'multiqc_general_stats.txt')
    def sources = new File(data_dir, 'multiqc_sources.txt')
    def failed_samples = new File(multiqc_dir, 'failed_samples.txt')

    assert report.exists() : 'Missing results/multiqc/multiqc_report.html'
    assert report.length() > 100_000 : 'Expected multiqc_report.html to be larger than 100 KB'
    assert fastp_table.exists() : 'Missing results/multiqc/multiqc_data/multiqc_fastp.txt'
    assert general_stats.exists() : 'Missing results/multiqc/multiqc_data/multiqc_general_stats.txt'
    assert sources.exists() : 'Missing results/multiqc/multiqc_data/multiqc_sources.txt'
    assert failed_samples.exists() : 'Missing results/multiqc/failed_samples.txt'
    assert failed_samples.text.trim().isEmpty() : 'Expected failed_samples.txt to be empty for PRJNA647806'

    def fastp_rows = fastp_table.readLines()
        .findAll { it.trim() && !it.startsWith('#') }
    if (fastp_rows && fastp_rows.first().toLowerCase().startsWith('sample')) {
        fastp_rows = fastp_rows.drop(1)
    }
    assert fastp_rows.size() == expected_samples.size() : "Expected ${expected_samples.size()} rows in multiqc_fastp.txt, observed ${fastp_rows.size()}"
}
