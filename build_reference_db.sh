
#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# Pipeline base directory
# ==========================================================

PIPELINE_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="${PIPELINE_BASE_DIR}/config"
DEPENDENCIES_CONFIG="${CONFIG_DIR}/dependencies.config"
ENV_CONFIG_DIR="${CONFIG_DIR}/environments"

# ==========================================================
# Defaults
# ==========================================================

ENVIRONMENT="production"

# ==========================================================
# Usage
# ==========================================================

usage() {
    cat <<EOF
Usage:
    bash build_reference_db.sh [options] [reference-db options]

Options:
    --env ENV       Environment: development or production
                    (default: production)
    -h, --help      Show this help message

All other arguments are passed to fluab-reference-db/bin/run_pipeline.sh.

Examples:
    bash build_reference_db.sh
    bash build_reference_db.sh --env development
    bash build_reference_db.sh --env production --outdir /path/to/output
    bash build_reference_db.sh --env development --batch 200

EOF
}

# ==========================================================
# Parse arguments
# ==========================================================

DB_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --env requires an argument." >&2
                exit 1
            fi
            ENVIRONMENT="$2"
            shift 2
            ;;
        --env=*)
            ENVIRONMENT="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            DB_ARGS+=("$1")
            shift
            ;;
    esac
done

# ==========================================================
# Validate environment
# ==========================================================

case "${ENVIRONMENT}" in
    development|production)
        ;;
    *)
        echo "ERROR: Invalid environment '${ENVIRONMENT}'." >&2
        echo "       Choose development or production." >&2
        exit 1
        ;;
esac

# ==========================================================
# Load configuration
# ==========================================================

if [[ ! -f "${DEPENDENCIES_CONFIG}" ]]; then
    echo "ERROR: Dependencies configuration not found: ${DEPENDENCIES_CONFIG}" >&2
    exit 1
fi

ENV_CONFIG="${ENV_CONFIG_DIR}/${ENVIRONMENT}.config"

if [[ ! -f "${ENV_CONFIG}" ]]; then
    echo "ERROR: Environment configuration not found: ${ENV_CONFIG}" >&2
    exit 1
fi

source "${DEPENDENCIES_CONFIG}"
source "${ENV_CONFIG}"

# ==========================================================
# Validate reference database pipeline
# ==========================================================

DB_LAUNCHER="${FLUAB_DB_PIPELINE_DIR}/bin/run_pipeline.sh"

if [[ ! -f "${DB_LAUNCHER}" ]]; then
    echo "ERROR: Reference database launcher not found: ${DB_LAUNCHER}" >&2
    exit 1
fi

# ==========================================================
# Run reference database pipeline
# ==========================================================

echo "=========================================================="
echo " Influenza reference database"
echo "=========================================================="
echo "Environment: ${ENVIRONMENT}"
echo "Pipeline:    ${FLUAB_DB_PIPELINE_DIR}"
echo "=========================================================="

bash "${DB_LAUNCHER}" "${DB_ARGS[@]}"
