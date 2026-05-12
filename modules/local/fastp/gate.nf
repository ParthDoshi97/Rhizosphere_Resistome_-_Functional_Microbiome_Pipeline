nextflow.enable.dsl = 2

process FASTP_QC_GATE {
    label 'process_single'

    container 'python:3.11-slim'

    input:
    tuple val(meta), path(json)

    output:
    tuple val(meta), path(json), path("${meta.id}.qc_pass.txt"), emit: pass, optional: true
    tuple val(meta), path(json), path("${meta.id}.qc_fail.txt"), emit: fail, optional: true

    script:
    def meta_json = groovy.json.JsonOutput.toJson(meta)
    def thresholds_json = groovy.json.JsonOutput.toJson([
        fastp_min_reads      : params.fastp_min_reads,
        fastp_min_bases_gbp  : params.fastp_min_bases_gbp,
        fastp_min_q30_rate   : params.fastp_min_q30_rate,
        fastp_max_dup_rate   : params.fastp_max_dup_rate,
        fastp_min_gc         : params.fastp_min_gc,
        fastp_max_gc         : params.fastp_max_gc,
        fastp_depth_fraction : params.fastp_depth_fraction
    ])

    """
cat > meta.json <<'END_META'
${meta_json}
END_META

cat > thresholds.json <<'END_THRESHOLDS'
${thresholds_json}
END_THRESHOLDS

python3 - <<'PY'
import json
from pathlib import Path

json_path = Path('${json}')

with open('meta.json', 'r', encoding='utf-8') as handle:
    meta = json.load(handle)

with open('thresholds.json', 'r', encoding='utf-8') as handle:
    thresholds = json.load(handle)

with json_path.open('r', encoding='utf-8') as handle:
    fastp = json.load(handle)

sample_id = str(meta['id'])
exp_depth = float(meta.get('exp_depth') or 0)

def metric(path):
    node = fastp
    for key in path:
        if not isinstance(node, dict) or key not in node:
            raise KeyError('.'.join(path))
        node = node[key]
    return node

def as_float(path):
    value = metric(path)
    if value is None:
        raise ValueError('.'.join(path))
    return float(value)

failures = []
missing = []

try:
    passed_filter_reads = as_float(['filtering_result', 'passed_filter_reads'])
    read_pairs = passed_filter_reads / 2.0
except (KeyError, TypeError, ValueError) as exc:
    read_pairs = None
    missing.append('filtering_result.passed_filter_reads ({})'.format(exc))

try:
    total_bases = as_float(['summary', 'after_filtering', 'total_bases'])
    bases_gbp = total_bases / 1_000_000_000.0
except (KeyError, TypeError, ValueError) as exc:
    total_bases = None
    bases_gbp = None
    missing.append('summary.after_filtering.total_bases ({})'.format(exc))

try:
    q30_rate = as_float(['summary', 'after_filtering', 'q30_rate'])
except (KeyError, TypeError, ValueError) as exc:
    q30_rate = None
    missing.append('summary.after_filtering.q30_rate ({})'.format(exc))

try:
    duplication_rate = as_float(['duplication', 'rate'])
except (KeyError, TypeError, ValueError) as exc:
    duplication_rate = None
    missing.append('duplication.rate ({})'.format(exc))

try:
    gc_content = as_float(['summary', 'after_filtering', 'gc_content'])
except (KeyError, TypeError, ValueError) as exc:
    gc_content = None
    missing.append('summary.after_filtering.gc_content ({})'.format(exc))

if read_pairs is not None and read_pairs < float(thresholds['fastp_min_reads']):
    failures.append(
        'post-filter read count too low: observed {:.0f} read pairs; required >= {:.0f}'.format(
            read_pairs, float(thresholds['fastp_min_reads'])
        )
    )

if bases_gbp is not None and bases_gbp < float(thresholds['fastp_min_bases_gbp']):
    failures.append(
        'post-filter base yield too low: observed {:.3f} Gbp; required >= {:.3f} Gbp'.format(
            bases_gbp, float(thresholds['fastp_min_bases_gbp'])
        )
    )

if q30_rate is not None and q30_rate < float(thresholds['fastp_min_q30_rate']):
    failures.append(
        'mean quality too low: observed Q30 rate {:.3f}; required >= {:.3f}'.format(
            q30_rate, float(thresholds['fastp_min_q30_rate'])
        )
    )

if duplication_rate is not None and duplication_rate > float(thresholds['fastp_max_dup_rate']):
    failures.append(
        'duplication rate too high: observed {:.3f}; required <= {:.3f}'.format(
            duplication_rate, float(thresholds['fastp_max_dup_rate'])
        )
    )

if gc_content is not None:
    min_gc = float(thresholds['fastp_min_gc'])
    max_gc = float(thresholds['fastp_max_gc'])
    if gc_content < min_gc or gc_content > max_gc:
        failures.append(
            'GC content out of range: observed {:.3f}; required between {:.3f} and {:.3f}'.format(
                gc_content, min_gc, max_gc
            )
        )

if exp_depth > 0 and bases_gbp is not None:
    min_expected_gbp = exp_depth * float(thresholds['fastp_depth_fraction'])
    if bases_gbp < min_expected_gbp:
        failures.append(
            'expected depth mismatch: observed {:.3f} Gbp; expected depth {:.3f} Gbp, minimum allowed {:.3f} Gbp'.format(
                bases_gbp, exp_depth, min_expected_gbp
            )
        )

for item in missing:
    failures.append('required fastp JSON field missing or invalid: {}'.format(item))

metrics_summary = (
    'sample_id={sample_id}; read_pairs={read_pairs}; bases_gbp={bases_gbp}; '
    'q30_rate={q30_rate}; gc_content={gc_content}; duplication_rate={duplication_rate}; '
    'exp_depth_gbp={exp_depth}'
).format(
    sample_id=sample_id,
    read_pairs='NA' if read_pairs is None else '{:.0f}'.format(read_pairs),
    bases_gbp='NA' if bases_gbp is None else '{:.3f}'.format(bases_gbp),
    q30_rate='NA' if q30_rate is None else '{:.3f}'.format(q30_rate),
    gc_content='NA' if gc_content is None else '{:.3f}'.format(gc_content),
    duplication_rate='NA' if duplication_rate is None else '{:.3f}'.format(duplication_rate),
    exp_depth='{:.3f}'.format(exp_depth),
)

if failures:
    report_path = Path(sample_id + '.qc_fail.txt')
    report_path.write_text(
        'FAIL\\n' + metrics_summary + '\\n' + '\\n'.join('- ' + item for item in failures) + '\\n',
        encoding='utf-8'
    )
else:
    report_path = Path(sample_id + '.qc_pass.txt')
    report_path.write_text('PASS\\n' + metrics_summary + '\\n', encoding='utf-8')
PY
    """
}
