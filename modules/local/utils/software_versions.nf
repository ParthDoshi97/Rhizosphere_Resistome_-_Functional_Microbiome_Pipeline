nextflow.enable.dsl = 2

process PUBLISH_SOFTWARE_VERSIONS {
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container 'python:3.11'

    input:
    path version_files, stageAs: 'versions/version_*.yml'

    output:
    path "software_versions.yml", emit: software_versions

    script:
    """
set -euo pipefail
cat versions/* > software_versions.yml
    """
}
