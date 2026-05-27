#!/usr/bin/env python3
"""Validate and normalize the rhizosphere metagenome samplesheet."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path


ALIASES = {
    "sample": ("sample", "sample_id", "id"),
    "reads_r1": ("reads_r1", "r1", "fastq_1"),
    "reads_r2": ("reads_r2", "r2", "fastq_2"),
    "site": ("site",),
    "timepoint": ("timepoint",),
    "replicate": ("replicate",),
    "batch": ("batch",),
    "exp_depth": ("exp_depth", "expected_depth", "expected_gbp"),
}

OUTPUT_COLUMNS = [
    "sample",
    "reads_r1",
    "reads_r2",
    "site",
    "timepoint",
    "replicate",
    "batch",
    "exp_depth",
]

REMOTE_PREFIXES = ("s3://", "gs://", "az://", "http://", "https://")
FASTQ_SUFFIXES = (".fastq.gz", ".fq.gz", ".fastq", ".fq")
SAMPLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
METADATA_RE = re.compile(r"^[A-Za-z0-9_.:-]*$")


def split_lanes(value: str) -> list[str]:
    return [item.strip() for item in re.split(r"[;,]", value or "") if item.strip()]


def pick(row: dict[str, str], logical_name: str) -> str:
    for column in ALIASES[logical_name]:
        if column in row and str(row[column]).strip():
            return str(row[column]).strip()
    return ""


def normalize_path(path: str) -> str:
    return path.strip().strip('"').strip("'")


def is_remote(path: str) -> bool:
    return path.lower().startswith(REMOTE_PREFIXES)


def validate_fastq_path(path: str, row_number: int, column: str, errors: list[str]) -> None:
    cleaned = normalize_path(path)
    lower = cleaned.lower().split("?", 1)[0]

    if any(char.isspace() for char in cleaned):
        errors.append(f"row {row_number}: {column} path contains whitespace: {cleaned!r}")

    if not lower.endswith(FASTQ_SUFFIXES):
        errors.append(
            f"row {row_number}: {column} must end with one of "
            f"{', '.join(FASTQ_SUFFIXES)}: {cleaned!r}"
        )

    if not is_remote(cleaned) and "://" in cleaned:
        errors.append(f"row {row_number}: unsupported URI scheme in {column}: {cleaned!r}")


def validate_metadata(value: str, row_number: int, column: str, errors: list[str]) -> None:
    if value and not METADATA_RE.match(value):
        errors.append(
            f"row {row_number}: {column} contains unsupported characters; "
            "use letters, numbers, underscore, dash, dot, colon, or leave it blank"
        )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="Input samplesheet CSV")
    parser.add_argument("--output", required=True, type=Path, help="Normalized output CSV")
    parser.add_argument("--report", required=True, type=Path, help="Validation report JSON")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    errors: list[str] = []
    warnings: list[str] = []
    normalized_rows: list[dict[str, str]] = []
    seen_samples: set[str] = set()

    with args.input.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            errors.append("samplesheet is empty or missing a header row")
        else:
            fieldnames = [name.strip() for name in reader.fieldnames]
            reader.fieldnames = fieldnames

            for logical in ("sample", "reads_r1", "reads_r2"):
                if not any(column in fieldnames for column in ALIASES[logical]):
                    errors.append(
                        f"samplesheet missing required column for {logical}; "
                        f"accepted aliases: {', '.join(ALIASES[logical])}"
                    )

            for row_number, row in enumerate(reader, start=2):
                row = {str(key).strip(): (value or "").strip() for key, value in row.items()}
                sample = pick(row, "sample")
                reads_r1 = pick(row, "reads_r1")
                reads_r2 = pick(row, "reads_r2")
                site = pick(row, "site")
                timepoint = pick(row, "timepoint")
                replicate = pick(row, "replicate")
                batch = pick(row, "batch")
                exp_depth = pick(row, "exp_depth") or "0"

                if not sample:
                    errors.append(f"row {row_number}: sample ID is required")
                elif not SAMPLE_RE.match(sample):
                    errors.append(
                        f"row {row_number}: sample ID {sample!r} is invalid; "
                        "use letters, numbers, underscore, dash, and dot"
                    )
                elif sample in seen_samples:
                    errors.append(
                        f"row {row_number}: duplicate sample ID {sample!r}; "
                        "combine lanes in reads_r1/reads_r2 with semicolons or commas"
                    )
                else:
                    seen_samples.add(sample)

                r1_lanes = split_lanes(reads_r1)
                r2_lanes = split_lanes(reads_r2)
                if not r1_lanes:
                    errors.append(f"row {row_number}: reads_r1 is required")
                if not r2_lanes:
                    errors.append(f"row {row_number}: reads_r2 is required")
                if r1_lanes and r2_lanes and len(r1_lanes) != len(r2_lanes):
                    errors.append(
                        f"row {row_number}: reads_r1 has {len(r1_lanes)} lane(s), "
                        f"but reads_r2 has {len(r2_lanes)} lane(s)"
                    )

                for lane in r1_lanes:
                    validate_fastq_path(lane, row_number, "reads_r1", errors)
                for lane in r2_lanes:
                    validate_fastq_path(lane, row_number, "reads_r2", errors)

                for column, value in (
                    ("site", site),
                    ("timepoint", timepoint),
                    ("replicate", replicate),
                    ("batch", batch),
                ):
                    validate_metadata(value, row_number, column, errors)

                try:
                    if float(exp_depth) < 0:
                        errors.append(f"row {row_number}: exp_depth must be >= 0")
                except ValueError:
                    errors.append(f"row {row_number}: exp_depth must be numeric, observed {exp_depth!r}")

                if not batch:
                    warnings.append(f"row {row_number}: batch is blank; downstream grouping will use 'default'")

                normalized_rows.append(
                    {
                        "sample": sample,
                        "reads_r1": ";".join(normalize_path(item) for item in r1_lanes),
                        "reads_r2": ";".join(normalize_path(item) for item in r2_lanes),
                        "site": site,
                        "timepoint": timepoint,
                        "replicate": replicate,
                        "batch": batch,
                        "exp_depth": str(exp_depth),
                    }
                )

    report = {
        "input": str(args.input),
        "samples": len(normalized_rows),
        "errors": errors,
        "warnings": warnings,
        "status": "FAIL" if errors else "PASS",
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if errors:
        for message in errors:
            print(f"ERROR: {message}", file=sys.stderr)
        return 1

    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        writer.writerows(normalized_rows)

    for message in warnings:
        print(f"WARNING: {message}", file=sys.stderr)

    print(f"Validated {len(normalized_rows)} sample(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
