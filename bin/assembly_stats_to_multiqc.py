#!/usr/bin/env python3
"""Convert per-sample assembly_stats.tsv files to MultiQC custom content format."""

import sys
import csv
from pathlib import Path


MULTIQC_HEADER = """\
# id: 'assembly_stats'
# section_name: 'Assembly Statistics'
# description: 'MEGAHIT meta-large assembly statistics per sample'
# format: 'tsv'
# plot_type: 'table'
# pconfig:
#   id: 'assembly_stats_table'
#   title: 'MEGAHIT Assembly Statistics'
Sample\tTotal contigs\tTotal bases (Mbp)\tN50\tN90\tLargest contig\tContigs >=1kb\tContigs >=5kb\tStatus
"""


def main():
    if len(sys.argv) < 2:
        print("Usage: assembly_stats_to_multiqc.py <stats1.tsv> [stats2.tsv ...]", file=sys.stderr)
        sys.exit(1)

    rows = []
    for path in sys.argv[1:]:
        with open(path, newline='') as fh:
            reader = csv.DictReader(fh, delimiter='\t')
            for row in reader:
                rows.append(row)

    rows.sort(key=lambda r: r.get('sample_id', ''))

    out = Path('assembly_mqc.tsv')
    with out.open('w') as fh:
        fh.write(MULTIQC_HEADER)
        for row in rows:
            fh.write('\t'.join([
                row.get('sample_id', ''),
                row.get('total_contigs', ''),
                row.get('total_bases_mbp', ''),
                row.get('n50', ''),
                row.get('n90', ''),
                row.get('largest_contig', ''),
                row.get('contigs_1kb', ''),
                row.get('contigs_5kb', ''),
                row.get('status', ''),
            ]) + '\n')


if __name__ == '__main__':
    main()
