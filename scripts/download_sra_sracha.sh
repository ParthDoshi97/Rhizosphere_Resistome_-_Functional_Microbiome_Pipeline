#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="${0##*/}"

usage() {
    printf '%s\n' \
        "Download SRA/ENA/NCBI sequencing data with sracha." \
        "" \
        "Usage:" \
        "  bash scripts/download_sra_sracha.sh [options] ACCESSION [ACCESSION...]" \
        "  bash scripts/download_sra_sracha.sh [options] --accession-list accessions.txt" \
        "  bash scripts/download_sra_sracha.sh [options] --sample-sheet samples.csv" \
        "" \
        "Accessions can be SRA runs (SRR/ERR/DRR), studies (SRP/ERP/DRP), or" \
        "BioProjects (PRJNA/PRJEB/PRJDB). By default this runs \`sracha get\`," \
        "which downloads, converts to FASTQ, and gzip-compresses the output." \
        "" \
        "Common examples:" \
        "  bash scripts/download_sra_sracha.sh SRR28588231" \
        "" \
        "  bash scripts/download_sra_sracha.sh --sample-sheet samples.csv \\" \
        "    --accession-column run_accession \\" \
        "    --output-dir data/PRJNA647806/reads \\" \
        "    --prefer-ena" \
        "" \
        "  bash scripts/download_sra_sracha.sh PRJNA647806 --dry-run" \
        "" \
        "  bash scripts/download_sra_sracha.sh --accession-list SRR_Acc_List.txt \\" \
        "    --output-dir data/PRJNA647806/reads \\" \
        "    --s3-prefix s3://multiomic-project-data/data/PRJNA647806/reads \\" \
        "    --write-sample-sheet data/PRJNA647806/sample_sheet.csv" \
        "" \
        "Options:" \
        "  --sample-sheet FILE         Input CSV/TSV sample sheet to extract accessions." \
        "  --accession-column NAME     Column to use from input sample sheet [auto]." \
        "  --allow-non-sra-ids         Do not validate extracted IDs against SRA prefixes." \
        "  --accession-list FILE       File with one accession per line." \
        "  -O, --output-dir DIR        Output directory [data/sra_downloads]." \
        "  --mode MODE                 sracha mode: get, fetch, fastq, info, validate [get]." \
        "  -t, --threads N             Decode/compression threads [auto]." \
        "  --connections N             HTTP connections per file [8]." \
        "  --format FORMAT             Download format: sra or sralite [sra]." \
        "  --split MODE                FASTQ split mode [split-3]." \
        "  --paired-suffix STYLE       numeric (_1/_2) or r (_R1/_R2) [numeric]." \
        "  --metadata FORMAT           Metadata sidecar: tsv, json, both, or none [tsv]." \
        "  --prefer-ena                Try ENA FASTQ mirrors first where supported." \
        "  --prefer-sdl                Resolve downloads through SDL API." \
        "  --folder-per-accession      Store each accession in its own subdirectory." \
        "  --keep-sra                  Keep downloaded SRA files after FASTQ conversion." \
        "  --force                     Overwrite existing outputs." \
        "  --no-resume                 Re-download instead of resuming partial downloads." \
        "  --no-gzip                   Write uncompressed FASTQ." \
        "  --zstd                      Use zstd compression instead of gzip." \
        "  --gzip-level N              gzip compression level [sracha default: 1]." \
        "  --zstd-level N              zstd compression level [sracha default: 3]." \
        "  --min-read-len N            Drop reads shorter than N." \
        "  --include-technical         Keep technical reads." \
        "  --no-strict                 Downgrade strict integrity errors to warnings." \
        "  --dry-run                   Resolve accessions and report planned downloads." \
        "  --dry-run-format FORMAT     Dry-run output: tsv or json [tsv]." \
        "  --info-format FORMAT        Info output: table, tsv, or csv [table]." \
        "  --ask                       Do not pass sracha -y; let sracha ask for confirmation." \
        "  --no-progress               Disable progress bars." \
        "  --write-sample-sheet FILE   Write a paired-end Nextflow CSV sample sheet." \
        "  --sample-sheet-uri-prefix U Prefix sample sheet read paths, e.g. s3://bucket/prefix." \
        "  --sample-batch VALUE        Batch column value for generated sample sheet [download]." \
        "  --s3-prefix S3_URI          aws s3 sync output directory to this prefix after download." \
        "  --install                   If sracha is missing, try installing with cargo." \
        "  -h, --help                  Show this help." \
        "" \
        "Extra sracha flags can be passed after \`--\`."
}

log() {
    printf '[download-sra-sracha] %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

detect_threads() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu 2>/dev/null || printf '8'
    else
        printf '8'
    fi
}

install_sracha() {
    if command -v sracha >/dev/null 2>&1; then
        return 0
    fi

    if command -v cargo >/dev/null 2>&1; then
        log "Installing sracha with cargo"
        cargo install --git https://github.com/rnabioco/sracha-rs sracha
        return 0
    fi

    printf '%s\n' \
        "sracha is not installed and cargo was not found." \
        "" \
        "Install one of these, then rerun:" \
        "  cargo install --git https://github.com/rnabioco/sracha-rs sracha" \
        "  pixi add --channel bioconda sracha" \
        "  conda install -c bioconda sracha" >&2
    exit 1
}

require_command() {
    local cmd="$1"
    local message="$2"
    command -v "$cmd" >/dev/null 2>&1 || die "$message"
}

extract_accessions_with_python() {
    local sample_sheet="$1"
    local accession_column="$2"
    local output_file="$3"

    python3 - "$sample_sheet" "$accession_column" "$output_file" "$ALLOW_NON_SRA_IDS" <<'PY'
import csv
import re
import sys

sample_sheet, requested_column, output_file, allow_non_sra = sys.argv[1:5]
allow_non_sra = allow_non_sra == "1"

candidates = [
    "accession",
    "run_accession",
    "run",
    "sra_accession",
    "sra",
    "srr",
    "err",
    "drr",
    "bioproject",
    "study",
    "batch",
    "project",
    "id",
    "sample_id",
    "sample",
]

pattern = re.compile(r"^(SRR|ERR|DRR|SRP|ERP|DRP|PRJNA|PRJEB|PRJDB)\d+$")

def norm(value):
    return value.strip().lower().replace("-", "_").replace(" ", "_")

def split_values(raw):
    raw = (raw or "").strip()
    if not raw or raw.startswith("#"):
        return []
    values = []
    for item in re.split(r"[,\s;]+", raw):
        item = item.strip().strip("'\"")
        if item and not item.startswith("#"):
            values.append(item)
    return values

def values_from_column(rows, column):
    values = []
    seen = set()
    for row in rows:
        for item in split_values(row.get(column)):
            if item not in seen:
                seen.add(item)
                values.append(item)
    return values

def sra_like(values):
    return bool(values) and all(pattern.match(value) for value in values)

def accession_column_suggestions(rows, fieldnames):
    suggestions = []
    for field in fieldnames:
        values = values_from_column(rows, field)
        if sra_like(values):
            suggestions.append((field, values))
    return suggestions

with open(sample_sheet, newline="") as handle:
    sample = handle.read(4096)
    handle.seek(0)
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",\t;")
    except csv.Error:
        first_line = sample.splitlines()[0] if sample.splitlines() else ""
        dialect = csv.excel_tab if "\t" in first_line else csv.excel

    reader = csv.DictReader(handle, dialect=dialect)
    if not reader.fieldnames:
        raise SystemExit(f"ERROR: sample sheet has no header: {sample_sheet}")

    rows = list(reader)
    fields_by_norm = {norm(field): field for field in reader.fieldnames if field}
    if requested_column:
        selected = fields_by_norm.get(norm(requested_column))
        if selected is None:
            available = ", ".join(reader.fieldnames)
            raise SystemExit(
                f"ERROR: column {requested_column!r} not found in {sample_sheet}. "
                f"Available columns: {available}"
            )
    else:
        selected = None
        for name in candidates:
            column = fields_by_norm.get(name)
            if column and sra_like(values_from_column(rows, column)):
                selected = column
                break
        if selected is None:
            suggestions = accession_column_suggestions(rows, reader.fieldnames)
            if suggestions:
                selected = suggestions[0][0]
            else:
                available = ", ".join(reader.fieldnames)
                raise SystemExit(
                    "ERROR: could not auto-detect an accession column with SRA-like values. "
                    f"Use --accession-column. Available columns: {available}"
                )

    values = values_from_column(rows, selected)
    if not values:
        raise SystemExit(f"ERROR: no accessions found in column {selected!r}")

    bad = [value for value in values if not pattern.match(value)]
    if bad and not allow_non_sra:
        suggestions = accession_column_suggestions(rows, reader.fieldnames)
        suggestion_text = ""
        if suggestions:
            suggestion_bits = []
            for column, column_values in suggestions[:3]:
                suggestion_bits.append(f"{column} ({', '.join(column_values[:3])})")
            suggestion_text = " SRA-like values were found in: " + "; ".join(suggestion_bits) + "."
        available = ", ".join(reader.fieldnames)
        raise SystemExit(
            "ERROR: extracted IDs do not look like SRA run/study/BioProject accessions: "
            f"{', '.join(bad[:5])}.{suggestion_text} "
            "Use --accession-column to choose the real accession column, "
            "or --allow-non-sra-ids if you really want to pass these values to sracha. "
            f"Available columns: {available}"
        )

with open(output_file, "w", newline="\n") as out:
    for value in values:
        out.write(value + "\n")

print(f"[download-sra-sracha] Extracted {len(values)} accession(s) from column {selected!r}", file=sys.stderr)
PY
}

extract_accessions_with_awk() {
    local sample_sheet="$1"
    local accession_column="$2"
    local output_file="$3"
    local delimiter=","

    if head -n 1 "$sample_sheet" | grep -q "$(printf '\t')"; then
        delimiter="$(printf '\t')"
    fi

    awk -v FS="$delimiter" -v requested="$accession_column" -v allow_non_sra="$ALLOW_NON_SRA_IDS" '
        function norm(value) {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", value)
            gsub(/[- ]/, "_", value)
            return tolower(value)
        }
        function clean(value) {
            gsub(/^[ \t\r\n"\047]+|[ \t\r\n"\047]+$/, "", value)
            return value
        }
        function is_sra_like(value) {
            return value ~ /^(SRR|ERR|DRR|SRP|ERP|DRP|PRJNA|PRJEB|PRJDB)[0-9]+$/
        }
        BEGIN {
            candidate_count = split("accession run_accession run sra_accession sra srr err drr bioproject study batch project id sample_id sample", candidates, " ")
        }
        NR == 1 {
            NF_header = NF
            for (i = 1; i <= NF; i++) {
                header[norm($i)] = i
                original[i] = $i
            }
            if (requested != "") {
                col = header[norm(requested)]
                if (!col) {
                    print "ERROR: requested accession column not found: " requested > "/dev/stderr"
                    exit 2
                }
            }
            next
        }
        NR > 1 {
            for (field_idx = 1; field_idx <= NF; field_idx++) {
                n_field = split($field_idx, field_parts, /[,; \t]+/)
                for (j = 1; j <= n_field; j++) {
                    candidate_value = clean(field_parts[j])
                    if (candidate_value == "" || candidate_value ~ /^#/) {
                        continue
                    }
                    if (is_sra_like(candidate_value)) {
                        sra_count[field_idx]++
                    } else {
                        bad_count_by_col[field_idx]++
                    }
                }
            }
            rows[NR] = $0
            max_nr = NR
            next
        }
        END {
            if (!col) {
                if (requested != "") {
                    col = header[norm(requested)]
                } else {
                    for (i = 1; i <= candidate_count; i++) {
                        candidate_col = header[candidates[i]]
                        if (candidate_col && sra_count[candidate_col] > 0 && bad_count_by_col[candidate_col] == 0) {
                            col = candidate_col
                            break
                        }
                    }
                    if (!col) {
                        for (i = 1; i <= NF_header; i++) {
                            if (sra_count[i] > 0 && bad_count_by_col[i] == 0) {
                                col = i
                                break
                            }
                        }
                    }
                    if (!col) {
                        for (i = 1; i <= candidate_count; i++) {
                            candidate_col = header[candidates[i]]
                            if (candidate_col) {
                                col = candidate_col
                                break
                            }
                        }
                    }
                }
                if (!col) {
                    print "ERROR: could not auto-detect an accession column. Use --accession-column." > "/dev/stderr"
                    exit 2
                }
            }

            for (row_nr = 2; row_nr <= max_nr; row_nr++) {
                split(rows[row_nr], row_fields, FS)
                n = split(row_fields[col], parts, /[,; \t]+/)
                for (i = 1; i <= n; i++) {
                    value = clean(parts[i])
                    if (value == "" || value ~ /^#/) {
                        continue
                    }
                    if (!seen[value]++) {
                        values[++count] = value
                    }
                }
            }

            if (count == 0) {
                print "ERROR: no accessions found in selected column" > "/dev/stderr"
                exit 2
            }
            bad_count = 0
            for (i = 1; i <= count; i++) {
                if (!is_sra_like(values[i])) {
                    bad[++bad_count] = values[i]
                }
            }
            if (bad_count && allow_non_sra != "1") {
                message = "ERROR: extracted IDs do not look like SRA accessions: " bad[1] "."
                for (i = 1; i <= NF_header; i++) {
                    if (sra_count[i] > 0 && bad_count_by_col[i] == 0) {
                        message = message " Try --accession-column " original[i] "."
                        break
                    }
                }
                print message > "/dev/stderr"
                print "Use --accession-column to choose the real accession column, or --allow-non-sra-ids." > "/dev/stderr"
                exit 2
            }
            for (i = 1; i <= count; i++) {
                print values[i]
            }
        }
    ' "$sample_sheet" > "$output_file"

    log "Extracted accessions from sample sheet using awk fallback"
}

extract_accessions_from_sample_sheet() {
    local sample_sheet="$1"
    local accession_column="$2"
    local output_file="$3"

    [[ -f "$sample_sheet" ]] || die "sample sheet not found: $sample_sheet"

    if command -v python3 >/dev/null 2>&1; then
        extract_accessions_with_python "$sample_sheet" "$accession_column" "$output_file"
    else
        require_command awk "python3 or awk is required to parse --sample-sheet"
        require_command head "head is required to parse --sample-sheet without python3"
        require_command grep "grep is required to parse --sample-sheet without python3"
        extract_accessions_with_awk "$sample_sheet" "$accession_column" "$output_file"
    fi
}

trim_trailing_slash() {
    local value="$1"
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    printf '%s' "$value"
}

make_sample_sheet_path() {
    local file="$1"
    local rel="$file"

    if [[ -n "$SAMPLE_SHEET_URI_PREFIX" ]]; then
        if [[ "$file" == "$OUTPUT_DIR"/* ]]; then
            rel="${file#"$OUTPUT_DIR"/}"
        else
            rel="${file##*/}"
        fi
        printf '%s/%s' "$(trim_trailing_slash "$SAMPLE_SHEET_URI_PREFIX")" "$rel"
    else
        printf '%s' "$file"
    fi
}

write_sample_sheet() {
    local sample_sheet="$1"
    local sample_dir
    if [[ "$sample_sheet" == */* ]]; then
        sample_dir="${sample_sheet%/*}"
    else
        sample_dir="."
    fi
    mkdir -p "$sample_dir"

    declare -A r1_by_sample=()
    declare -A r2_by_sample=()
    local file base sample

    while IFS= read -r file; do
        base="${file##*/}"
        if [[ "$base" =~ ^(.+)(_R?1|_1)\.(fastq|fq)(\.gz|\.zst)?$ ]]; then
            sample="${BASH_REMATCH[1]}"
            r1_by_sample["$sample"]="$file"
        elif [[ "$base" =~ ^(.+)(_R?2|_2)\.(fastq|fq)(\.gz|\.zst)?$ ]]; then
            sample="${BASH_REMATCH[1]}"
            r2_by_sample["$sample"]="$file"
        fi
    done < <(
        find "$OUTPUT_DIR" -type f \( \
            -name '*.fastq' -o -name '*.fq' -o \
            -name '*.fastq.gz' -o -name '*.fq.gz' -o \
            -name '*.fastq.zst' -o -name '*.fq.zst' \
        \) | sort
    )

    {
        printf 'id,reads_r1,reads_r2,site,timepoint,replicate,batch,exp_depth\n'
        if [[ "${#r1_by_sample[@]}" -eq 0 ]]; then
            log "WARN: no paired FASTQ R1 files were found under $OUTPUT_DIR"
        fi
        for sample in $(printf '%s\n' "${!r1_by_sample[@]}" | sort); do
            if [[ -n "${r2_by_sample[$sample]:-}" ]]; then
                printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                    "$sample" \
                    "$(make_sample_sheet_path "${r1_by_sample[$sample]}")" \
                    "$(make_sample_sheet_path "${r2_by_sample[$sample]}")" \
                    "" "" "" "$SAMPLE_BATCH" "0"
            else
                log "WARN: skipping $sample in sample sheet because R2 was not found"
            fi
        done
    } > "$sample_sheet"

    log "Wrote sample sheet: $sample_sheet"
}

MODE="get"
OUTPUT_DIR="data/sra_downloads"
THREADS="$(detect_threads)"
CONNECTIONS="8"
FORMAT="sra"
SPLIT_MODE="split-3"
PAIRED_SUFFIX="numeric"
METADATA="tsv"
PREFER_ENA=0
PREFER_SDL=0
FOLDER_PER_ACCESSION=0
KEEP_SRA=0
FORCE=0
NO_RESUME=0
NO_GZIP=0
ZSTD=0
GZIP_LEVEL=""
ZSTD_LEVEL=""
MIN_READ_LEN=""
INCLUDE_TECHNICAL=0
NO_STRICT=0
DRY_RUN=0
DRY_RUN_FORMAT="tsv"
INFO_FORMAT="table"
ASSUME_YES=1
NO_PROGRESS=0
INSTALL=0
ACCESSION_LIST=""
INPUT_SAMPLE_SHEET=""
ACCESSION_COLUMN=""
ALLOW_NON_SRA_IDS=0
OUTPUT_SAMPLE_SHEET=""
SAMPLE_SHEET_URI_PREFIX=""
SAMPLE_BATCH="download"
S3_PREFIX=""
ACCESSIONS=()
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --accession-list)
            ACCESSION_LIST="${2:-}"
            [[ -n "$ACCESSION_LIST" ]] || die "--accession-list requires a file"
            shift 2
            ;;
        --sample-sheet|--input-sample-sheet|--from-sample-sheet)
            INPUT_SAMPLE_SHEET="${2:-}"
            [[ -n "$INPUT_SAMPLE_SHEET" ]] || die "--sample-sheet requires a file"
            shift 2
            ;;
        --accession-column)
            ACCESSION_COLUMN="${2:-}"
            [[ -n "$ACCESSION_COLUMN" ]] || die "--accession-column requires a column name"
            shift 2
            ;;
        --allow-non-sra-ids)
            ALLOW_NON_SRA_IDS=1
            shift
            ;;
        -O|--output-dir)
            OUTPUT_DIR="${2:-}"
            [[ -n "$OUTPUT_DIR" ]] || die "--output-dir requires a directory"
            shift 2
            ;;
        --mode)
            MODE="${2:-}"
            [[ -n "$MODE" ]] || die "--mode requires a value"
            shift 2
            ;;
        -t|--threads)
            THREADS="${2:-}"
            [[ -n "$THREADS" ]] || die "--threads requires a value"
            shift 2
            ;;
        --connections)
            CONNECTIONS="${2:-}"
            [[ -n "$CONNECTIONS" ]] || die "--connections requires a value"
            shift 2
            ;;
        --format)
            FORMAT="${2:-}"
            [[ -n "$FORMAT" ]] || die "--format requires a value"
            shift 2
            ;;
        --split)
            SPLIT_MODE="${2:-}"
            [[ -n "$SPLIT_MODE" ]] || die "--split requires a value"
            shift 2
            ;;
        --paired-suffix)
            PAIRED_SUFFIX="${2:-}"
            [[ -n "$PAIRED_SUFFIX" ]] || die "--paired-suffix requires a value"
            shift 2
            ;;
        --metadata)
            METADATA="${2:-}"
            [[ -n "$METADATA" ]] || die "--metadata requires a value"
            shift 2
            ;;
        --prefer-ena)
            PREFER_ENA=1
            shift
            ;;
        --prefer-sdl)
            PREFER_SDL=1
            shift
            ;;
        --folder-per-accession)
            FOLDER_PER_ACCESSION=1
            shift
            ;;
        --keep-sra)
            KEEP_SRA=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --no-resume)
            NO_RESUME=1
            shift
            ;;
        --no-gzip)
            NO_GZIP=1
            shift
            ;;
        --zstd)
            ZSTD=1
            shift
            ;;
        --gzip-level)
            GZIP_LEVEL="${2:-}"
            [[ -n "$GZIP_LEVEL" ]] || die "--gzip-level requires a value"
            shift 2
            ;;
        --zstd-level)
            ZSTD_LEVEL="${2:-}"
            [[ -n "$ZSTD_LEVEL" ]] || die "--zstd-level requires a value"
            shift 2
            ;;
        --min-read-len)
            MIN_READ_LEN="${2:-}"
            [[ -n "$MIN_READ_LEN" ]] || die "--min-read-len requires a value"
            shift 2
            ;;
        --include-technical)
            INCLUDE_TECHNICAL=1
            shift
            ;;
        --no-strict)
            NO_STRICT=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --dry-run-format)
            DRY_RUN_FORMAT="${2:-}"
            [[ -n "$DRY_RUN_FORMAT" ]] || die "--dry-run-format requires a value"
            shift 2
            ;;
        --info-format)
            INFO_FORMAT="${2:-}"
            [[ -n "$INFO_FORMAT" ]] || die "--info-format requires a value"
            shift 2
            ;;
        --ask)
            ASSUME_YES=0
            shift
            ;;
        --no-progress)
            NO_PROGRESS=1
            shift
            ;;
        --write-sample-sheet|--output-sample-sheet)
            OUTPUT_SAMPLE_SHEET="${2:-}"
            [[ -n "$OUTPUT_SAMPLE_SHEET" ]] || die "--write-sample-sheet requires a file"
            shift 2
            ;;
        --sample-sheet-uri-prefix)
            SAMPLE_SHEET_URI_PREFIX="${2:-}"
            [[ -n "$SAMPLE_SHEET_URI_PREFIX" ]] || die "--sample-sheet-uri-prefix requires a URI"
            shift 2
            ;;
        --sample-batch)
            SAMPLE_BATCH="${2:-}"
            [[ -n "$SAMPLE_BATCH" ]] || die "--sample-batch requires a value"
            shift 2
            ;;
        --s3-prefix)
            S3_PREFIX="${2:-}"
            [[ "$S3_PREFIX" == s3://* ]] || die "--s3-prefix must start with s3://"
            shift 2
            ;;
        --install)
            INSTALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            ACCESSIONS+=("$1")
            shift
            ;;
    esac
done

case "$MODE" in
    get|fetch|fastq|info|validate) ;;
    *) die "--mode must be one of: get, fetch, fastq, info, validate" ;;
esac

if [[ -n "$INPUT_SAMPLE_SHEET" && -n "$ACCESSION_LIST" ]]; then
    die "Use either --sample-sheet or --accession-list, not both"
fi

if [[ -z "$INPUT_SAMPLE_SHEET" && -z "$ACCESSION_LIST" && "${#ACCESSIONS[@]}" -eq 0 ]]; then
    usage >&2
    die "Provide --sample-sheet, --accession-list, or at least one accession/path"
fi

if [[ "$NO_GZIP" -eq 1 && "$ZSTD" -eq 1 ]]; then
    die "--no-gzip and --zstd cannot be used together"
fi

if [[ "$INSTALL" -eq 1 ]]; then
    install_sracha
else
    require_command sracha "sracha is not installed. Re-run with --install, or install from https://github.com/rnabioco/sracha-rs"
fi

if [[ -n "$S3_PREFIX" ]]; then
    require_command aws "aws CLI is required for --s3-prefix"
    if [[ -z "$SAMPLE_SHEET_URI_PREFIX" ]]; then
        SAMPLE_SHEET_URI_PREFIX="$S3_PREFIX"
    fi
fi

mkdir -p "$OUTPUT_DIR"

if [[ -n "$INPUT_SAMPLE_SHEET" ]]; then
    ACCESSION_LIST="$OUTPUT_DIR/.sracha_accessions_from_sample_sheet.txt"
    extract_accessions_from_sample_sheet "$INPUT_SAMPLE_SHEET" "$ACCESSION_COLUMN" "$ACCESSION_LIST"
    log "Using accession list extracted from sample sheet: $ACCESSION_LIST"
fi

CMD=(sracha "$MODE")

case "$MODE" in
    get)
        CMD+=(-O "$OUTPUT_DIR" -t "$THREADS" --connections "$CONNECTIONS" --format "$FORMAT")
        CMD+=(--split "$SPLIT_MODE" --paired-suffix "$PAIRED_SUFFIX")
        [[ "$METADATA" != "none" ]] && CMD+=(--metadata "$METADATA")
        [[ "$PREFER_ENA" -eq 1 ]] && CMD+=(--prefer-ena)
        [[ "$PREFER_SDL" -eq 1 ]] && CMD+=(--prefer-sdl)
        [[ "$FOLDER_PER_ACCESSION" -eq 1 ]] && CMD+=(--folder-per-accession)
        [[ "$KEEP_SRA" -eq 1 ]] && CMD+=(--keep-sra)
        [[ "$FORCE" -eq 1 ]] && CMD+=(-f)
        [[ "$NO_RESUME" -eq 1 ]] && CMD+=(--no-resume)
        [[ "$NO_GZIP" -eq 1 ]] && CMD+=(--no-gzip)
        [[ "$ZSTD" -eq 1 ]] && CMD+=(--zstd)
        [[ -n "$GZIP_LEVEL" ]] && CMD+=(--gzip-level "$GZIP_LEVEL")
        [[ -n "$ZSTD_LEVEL" ]] && CMD+=(--zstd-level "$ZSTD_LEVEL")
        [[ -n "$MIN_READ_LEN" ]] && CMD+=(--min-read-len "$MIN_READ_LEN")
        [[ "$INCLUDE_TECHNICAL" -eq 1 ]] && CMD+=(--include-technical)
        [[ "$NO_STRICT" -eq 1 ]] && CMD+=(--no-strict)
        [[ "$DRY_RUN" -eq 1 ]] && CMD+=(--dry-run --dry-run-format "$DRY_RUN_FORMAT")
        [[ "$ASSUME_YES" -eq 1 ]] && CMD+=(-y)
        [[ "$NO_PROGRESS" -eq 1 ]] && CMD+=(--no-progress)
        ;;
    fetch)
        CMD+=(-O "$OUTPUT_DIR" --connections "$CONNECTIONS" --format "$FORMAT")
        [[ "$PREFER_ENA" -eq 1 ]] && CMD+=(--prefer-ena)
        [[ "$PREFER_SDL" -eq 1 ]] && CMD+=(--prefer-sdl)
        [[ "$FORCE" -eq 1 ]] && CMD+=(-f)
        [[ "$NO_RESUME" -eq 1 ]] && CMD+=(--no-resume)
        [[ "$ASSUME_YES" -eq 1 ]] && CMD+=(-y)
        [[ "$NO_PROGRESS" -eq 1 ]] && CMD+=(--no-progress)
        ;;
    fastq)
        CMD+=(-O "$OUTPUT_DIR" -t "$THREADS")
        CMD+=(--split "$SPLIT_MODE" --paired-suffix "$PAIRED_SUFFIX")
        [[ "$FOLDER_PER_ACCESSION" -eq 1 ]] && CMD+=(--folder-per-accession)
        [[ "$FORCE" -eq 1 ]] && CMD+=(-f)
        [[ "$NO_GZIP" -eq 1 ]] && CMD+=(--no-gzip)
        [[ "$ZSTD" -eq 1 ]] && CMD+=(--zstd)
        [[ -n "$GZIP_LEVEL" ]] && CMD+=(--gzip-level "$GZIP_LEVEL")
        [[ -n "$ZSTD_LEVEL" ]] && CMD+=(--zstd-level "$ZSTD_LEVEL")
        [[ -n "$MIN_READ_LEN" ]] && CMD+=(--min-read-len "$MIN_READ_LEN")
        [[ "$INCLUDE_TECHNICAL" -eq 1 ]] && CMD+=(--include-technical)
        [[ "$NO_STRICT" -eq 1 ]] && CMD+=(--no-strict)
        [[ "$NO_PROGRESS" -eq 1 ]] && CMD+=(--no-progress)
        ;;
    info)
        CMD+=(--format "$INFO_FORMAT")
        [[ "$PREFER_ENA" -eq 1 ]] && CMD+=(--prefer-ena)
        ;;
    validate)
        CMD+=(-t "$THREADS")
        [[ "$NO_PROGRESS" -eq 1 ]] && CMD+=(--no-progress)
        ;;
esac

if [[ -n "$ACCESSION_LIST" ]]; then
    CMD+=(--accession-list "$ACCESSION_LIST")
fi

CMD+=("${ACCESSIONS[@]}")
CMD+=("${EXTRA_ARGS[@]}")

log "Running: ${CMD[*]}"
"${CMD[@]}"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run finished; no files were downloaded."
    exit 0
fi

if [[ -n "$OUTPUT_SAMPLE_SHEET" && ( "$MODE" == "get" || "$MODE" == "fastq" ) ]]; then
    write_sample_sheet "$OUTPUT_SAMPLE_SHEET"
elif [[ -n "$OUTPUT_SAMPLE_SHEET" ]]; then
    log "WARN: --write-sample-sheet is only generated for --mode get or --mode fastq"
fi

if [[ -n "$S3_PREFIX" ]]; then
    log "Syncing $OUTPUT_DIR to $S3_PREFIX"
    aws s3 sync "$OUTPUT_DIR" "$S3_PREFIX"
fi

log "Done"
