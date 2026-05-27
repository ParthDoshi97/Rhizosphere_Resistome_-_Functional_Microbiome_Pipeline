nextflow.enable.dsl = 2

process VALIDATE_SAMPLESHEET {
    tag "$sample_sheet"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container 'python:3.11'

    input:
    path sample_sheet

    output:
    path "samplesheet.valid.csv",       emit: validated_csv
    path "samplesheet.validation.json", emit: validation_report
    path "versions.yml",                emit: versions

    script:
    """
set -euo pipefail

python3 ${projectDir}/bin/validate_samplesheet.py \\
    --input ${sample_sheet} \\
    --output samplesheet.valid.csv \\
    --report samplesheet.validation.json

cat > versions.yml <<END_VERSIONS
"${task.process}":
    python: \$(python3 --version | sed 's/Python //')
END_VERSIONS
    """
}
