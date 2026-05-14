#!/usr/bin/env python3
"""Merge CoverM MetaBAT-format coverage TSVs for SemiBin2."""

from __future__ import annotations

import csv
import sys
from collections import OrderedDict
from pathlib import Path


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def find_metabat_columns(header: list[str]) -> tuple[int, int, int, int, int]:
    required = ["contigName", "contigLen", "totalAvgDepth"]
    positions = []
    for column in required:
        try:
            positions.append(header.index(column))
        except ValueError:
            die(f"Missing required column {column!r} in header: {header}")

    depth_idx = None
    var_idx = None
    for idx, column in enumerate(header):
        if idx in positions:
            continue
        if column.endswith(".bam-var"):
            var_idx = idx
        elif column.endswith(".bam"):
            depth_idx = idx

    if depth_idx is None or var_idx is None:
        if len(header) < 5:
            die(f"Expected at least 5 MetaBAT columns, found {len(header)}: {header}")
        depth_idx = 3
        var_idx = 4

    return positions[0], positions[1], positions[2], depth_idx, var_idx


def sample_name_from_columns(header: list[str], depth_idx: int, var_idx: int, path: Path) -> tuple[str, str]:
    depth_name = header[depth_idx]
    var_name = header[var_idx]

    if depth_name == "totalAvgDepth" or var_name == "totalAvgDepth":
        die(f"Could not identify sample depth/variance columns in {path}")

    return depth_name, var_name


def read_coverm_tsv(path: Path) -> tuple[str, str, OrderedDict[str, dict[str, str]]]:
    with path.open(newline="") as handle:
        reader = csv.reader(handle, delimiter="\t")
        header = next(reader, None)
        if not header:
            die(f"{path} is empty")

        contig_idx, length_idx, _total_idx, depth_idx, var_idx = find_metabat_columns(header)
        depth_name, var_name = sample_name_from_columns(header, depth_idx, var_idx, path)

        rows: OrderedDict[str, dict[str, str]] = OrderedDict()
        for row in reader:
            if not row or len(row) <= max(contig_idx, length_idx, depth_idx, var_idx):
                continue

            contig = row[contig_idx]
            rows[contig] = {
                "length": row[length_idx],
                "depth": row[depth_idx] or "0",
                "variance": row[var_idx] or "0",
            }

    return depth_name, var_name, rows


def to_float(value: str) -> float:
    try:
        return float(value)
    except ValueError:
        return 0.0


def main(argv: list[str]) -> int:
    if not argv:
        die("Usage: merge_coverm_metabat.py SAMPLE_A.tsv [SAMPLE_B.tsv ...]")

    samples = []
    contig_order: OrderedDict[str, None] = OrderedDict()
    contig_lengths: dict[str, str] = {}

    for arg in argv:
        path = Path(arg)
        depth_name, var_name, rows = read_coverm_tsv(path)
        samples.append((depth_name, var_name, rows))

        for contig, values in rows.items():
            contig_order.setdefault(contig, None)
            contig_lengths.setdefault(contig, values["length"])

    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    header = ["contigName", "contigLen", "totalAvgDepth"]
    for depth_name, var_name, _rows in samples:
        header.extend([depth_name, var_name])
    writer.writerow(header)

    for contig in contig_order:
        depths = []
        sample_columns = []

        for _depth_name, _var_name, rows in samples:
            values = rows.get(contig)
            if values is None:
                depth = "0"
                variance = "0"
            else:
                depth = values["depth"]
                variance = values["variance"]

            depths.append(to_float(depth))
            sample_columns.extend([depth, variance])

        total_avg_depth = sum(depths) / len(depths) if depths else 0.0
        writer.writerow([
            contig,
            contig_lengths.get(contig, "0"),
            f"{total_avg_depth:.6g}",
            *sample_columns,
        ])

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
