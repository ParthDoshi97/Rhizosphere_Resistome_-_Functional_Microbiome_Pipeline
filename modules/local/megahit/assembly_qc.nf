nextflow.enable.dsl = 2

process ASSEMBLY_QC {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container 'python:3.11'

    input:
    tuple val(meta), path(contigs)

    output:
    tuple val(meta), path(contigs), path("${meta.id}.assembly_pass.txt"), emit: pass, optional: true
    tuple val(meta), path(contigs), path("${meta.id}.assembly_fail.txt"), emit: fail, optional: true
    tuple val(meta), path("${meta.id}.assembly_stats.tsv"), emit: stats
    path "versions.yml", emit: versions

    script:
    def thresholds_json = groovy.json.JsonOutput.toJson([
        assembly_min_bases_mbp   : params.assembly_min_bases_mbp,
        assembly_min_n50_bp      : params.assembly_min_n50_bp,
        assembly_min_contigs_1kb : params.assembly_min_contigs_1kb,
        assembly_max_contigs     : params.assembly_max_contigs
    ])
    def meta_json = groovy.json.JsonOutput.toJson(meta)

    """
set -euo pipefail

cat > meta.json <<'END_META'
${meta_json}
END_META

cat > thresholds.json <<'END_THRESHOLDS'
${thresholds_json}
END_THRESHOLDS

python3 - <<'PY'
import json
from pathlib import Path

with open('meta.json') as f:
    meta = json.load(f)

with open('thresholds.json') as f:
    thresholds = json.load(f)

sample_id = str(meta['id'])
contigs_path = Path('${contigs}')

lengths = []
with contigs_path.open() as fh:
    seq_len = 0
    for line in fh:
        line = line.rstrip()
        if line.startswith('>'):
            if seq_len > 0:
                lengths.append(seq_len)
            seq_len = 0
        else:
            seq_len += len(line)
    if seq_len > 0:
        lengths.append(seq_len)

lengths.sort(reverse=True)

total_contigs = len(lengths)
total_bases   = sum(lengths)
total_bases_mbp = total_bases / 1_000_000.0
mean_len      = total_bases / total_contigs if total_contigs else 0
largest       = lengths[0] if lengths else 0
contigs_1kb   = sum(1 for l in lengths if l >= 1000)
contigs_5kb   = sum(1 for l in lengths if l >= 5000)
contigs_10kb  = sum(1 for l in lengths if l >= 10000)

cum = 0
n50 = n90 = 0
half = total_bases * 0.5
ninety = total_bases * 0.9
for l in lengths:
    cum += l
    if n50 == 0 and cum >= half:
        n50 = l
    if n90 == 0 and cum >= ninety:
        n90 = l

failures = []
if total_bases_mbp < float(thresholds['assembly_min_bases_mbp']):
    failures.append('total bases too low: {:.1f} Mbp < {:.1f} Mbp'.format(
        total_bases_mbp, float(thresholds['assembly_min_bases_mbp'])))
if n50 < int(thresholds['assembly_min_n50_bp']):
    failures.append('N50 too low: {} bp < {} bp'.format(n50, thresholds['assembly_min_n50_bp']))
if contigs_1kb < int(thresholds['assembly_min_contigs_1kb']):
    failures.append('contigs >= 1kb too few: {} < {}'.format(contigs_1kb, thresholds['assembly_min_contigs_1kb']))
if total_contigs > int(thresholds['assembly_max_contigs']):
    failures.append('total contigs too high: {} > {}'.format(total_contigs, thresholds['assembly_max_contigs']))

status = 'FAIL' if failures else 'PASS'

tsv_path = Path(sample_id + '.assembly_stats.tsv')
tsv_path.write_text(
    'sample_id\ttotal_contigs\ttotal_bases_mbp\tn50\tn90\tlargest_contig\tcontigs_1kb\tcontigs_5kb\tcontigs_10kb\tmean_len\tstatus\n'
    '{}\t{}\t{:.1f}\t{}\t{}\t{}\t{}\t{}\t{}\t{:.0f}\t{}\n'.format(
        sample_id, total_contigs, total_bases_mbp, n50, n90,
        largest, contigs_1kb, contigs_5kb, contigs_10kb, mean_len, status
    )
)

summary = 'sample_id={}; total_bases_mbp={:.1f}; n50={}; contigs_1kb={}; total_contigs={}'.format(
    sample_id, total_bases_mbp, n50, contigs_1kb, total_contigs)

if failures:
    Path(sample_id + '.assembly_fail.txt').write_text('FAIL\n' + summary + '\n' + '\n'.join('- ' + f for f in failures) + '\n')
else:
    Path(sample_id + '.assembly_pass.txt').write_text('PASS\n' + summary + '\n')
PY

cat > versions.yml <<END_VERSIONS
"${task.process}":
    python: \$(python3 --version | sed 's/Python //')
END_VERSIONS
    """
}
