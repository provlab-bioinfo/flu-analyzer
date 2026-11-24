#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# Pipeline base directory
# ==========================================================

PIPELINE_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="${PIPELINE_BASE_DIR}/config"
PIPELINE_CONFIG_DIR="${CONFIG_DIR}/pipelines"
ENV_CONFIG_DIR="${CONFIG_DIR}/environments"

VERSION_FILE="${PIPELINE_BASE_DIR}/VERSION"
MASTER_REPORT_SCRIPT="${PIPELINE_BASE_DIR}/scripts/create_master_report.py"

VERSION="unknown"
if [[ -f "$VERSION_FILE" ]]; then
    VERSION="$(<"$VERSION_FILE")"
fi

ENVIRONMENT="production"

# ==========================================================
# Functions
# ==========================================================

usage() {
    cat <<EOF

flu-analyzer v${VERSION}

Run influenza QC and analysis pipelines.

Usage:
    $(basename "$0") <samplesheet.csv> <results_dir> [options]

Arguments:
    samplesheet.csv       Input samplesheet for nf-qcflow
    results_dir           Output directory

Options:
    --env ENV             Environment: development or production
                          Default: production
    -h, --help            Show this help message
    -v, --version         Show version

Example:
    ./run_flu.sh samplesheet.csv results/
    ./run_flu.sh samplesheet.csv results/ --env development

EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    local exit_code="${1:-1}"
    local line="${2:-unknown}"

    log "ERROR: Pipeline failed at line ${line} (exit code: ${exit_code})."
    exit "$exit_code"
}

run_cmd() {
    printf -v CMD '%q ' "$@"
    log "Running: ${CMD}"

    "$@" 2>&1 | tee -a "$LOG_FILE"
}

# ==========================================================
# Parse arguments
# ==========================================================

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --env requires an environment name."
                exit 1
            fi
            ENVIRONMENT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -v|--version)
            echo "$VERSION"
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL_ARGS[@]} -ne 2 ]]; then
    echo "ERROR: Please provide an input samplesheet and results directory."
    usage
    exit 1
fi

SAMPLESHEET="${POSITIONAL_ARGS[0]}"
RESULTS_DIR="${POSITIONAL_ARGS[1]}"

# ==========================================================
# Load configuration
# ==========================================================

if [[ ! "$ENVIRONMENT" =~ ^(development|production)$ ]]; then
    echo "ERROR: Invalid environment: ${ENVIRONMENT}"
    echo "Valid environments: development, production"
    exit 1
fi

DEPENDENCIES_CONFIG="${CONFIG_DIR}/dependencies.config"
ENV_CONFIG="${ENV_CONFIG_DIR}/${ENVIRONMENT}.config"

if [[ ! -f "$DEPENDENCIES_CONFIG" ]]; then
    echo "ERROR: Dependencies configuration not found: ${DEPENDENCIES_CONFIG}"
    exit 1
fi

if [[ ! -f "$ENV_CONFIG" ]]; then
    echo "ERROR: Environment configuration not found: ${ENV_CONFIG}"
    exit 1
fi

# Source dependencies first because environment configuration
# uses variables defined in dependencies.config.

source "$DEPENDENCIES_CONFIG"
source "$ENV_CONFIG"

QCFLOW_CONFIG="${PIPELINE_CONFIG_DIR}/nf-qcflow.config"
FLUAB_CONFIG="${PIPELINE_CONFIG_DIR}/nf-fluab.config"

# ==========================================================
# Validate input and configuration
# ==========================================================

if [[ ! -f "$SAMPLESHEET" ]]; then
    echo "ERROR: Input samplesheet not found: ${SAMPLESHEET}"
    exit 1
fi

SAMPLESHEET="$(cd "$(dirname "$SAMPLESHEET")" && pwd)/$(basename "$SAMPLESHEET")"

if [[ ! -f "$QCFLOW_CONFIG" ]]; then
    echo "ERROR: nf-qcflow configuration not found: ${QCFLOW_CONFIG}"
    exit 1
fi

if [[ ! -f "$FLUAB_CONFIG" ]]; then
    echo "ERROR: nf-fluab configuration not found: ${FLUAB_CONFIG}"
    exit 1
fi

if [[ ! -f "${NF_QCFLOW_DIR}/main.nf" ]]; then
    echo "ERROR: nf-qcflow pipeline not found: ${NF_QCFLOW_DIR}/main.nf"
    exit 1
fi

if [[ ! -f "${NF_FLUAB_DIR}/main.nf" ]]; then
    echo "ERROR: nf-fluab pipeline not found: ${NF_FLUAB_DIR}/main.nf"
    exit 1
fi

if [[ ! -f "$MASTER_REPORT_SCRIPT" ]]; then
    echo "ERROR: Master report script not found: ${MASTER_REPORT_SCRIPT}"
    exit 1
fi

if [[ ! -d "$FLUAB_DB" ]]; then
    echo "ERROR: Influenza reference database not found: ${FLUAB_DB}"
    exit 1
fi

if ! command -v nextflow >/dev/null 2>&1; then
    echo "ERROR: Nextflow is not available in PATH."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: Python 3 is not available in PATH."
    exit 1
fi

# ==========================================================
# Prepare output directories
# ==========================================================

mkdir -p "$RESULTS_DIR"
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd)"

QC_OUTDIR="${RESULTS_DIR}/nf-qcflow"
FLUAB_OUTDIR="${RESULTS_DIR}/nf-fluab"
MASTER_REPORT_OUTDIR="${RESULTS_DIR}/master_report"
LOG_OUTDIR="${RESULTS_DIR}/logs"

mkdir -p \
    "$QC_OUTDIR" \
    "$FLUAB_OUTDIR" \
    "$MASTER_REPORT_OUTDIR" \
    "$LOG_OUTDIR"

LOG_FILE="${LOG_OUTDIR}/pipeline.log"
RUN_INFO_FILE="${RESULTS_DIR}/run_info.txt"

trap 'error_exit $? $LINENO' ERR

# ==========================================================
# Pipeline information
# ==========================================================

FLUAB_DB_TARGET="$(readlink -f "$FLUAB_DB")"
RUN_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

log "=========================================================="
log "flu-analyzer v${VERSION}"
log "=========================================================="
log "Pipeline base directory: ${PIPELINE_BASE_DIR}"
log "Environment: ${ENVIRONMENT}"
log "Input samplesheet: ${SAMPLESHEET}"
log "Results directory: ${RESULTS_DIR}"
log "Nextflow profile: ${NF_PROFILE}"
log ""
log "Pipeline versions:"
log "  flu-analyzer: ${VERSION}"
log "  nf-qcflow: ${NF_QCFLOW_VERSION}"
log "  nf-fluab: ${NF_FLUAB_VERSION}"
log "  fluab-reference-db: ${FLUAB_REFERENCE_DB_VERSION}"
log "Reference database: ${FLUAB_DB_TARGET}"
log ""

# ==========================================================
# Create run information file
# ==========================================================

cat > "$RUN_INFO_FILE" <<EOF
flu-analyzer version: ${VERSION}
Analysis date: ${RUN_DATE}
Environment: ${ENVIRONMENT}
Input samplesheet: ${SAMPLESHEET}
Nextflow profile: ${NF_PROFILE}

Pipeline versions:
  flu-analyzer: ${VERSION}
  nf-qcflow: ${NF_QCFLOW_VERSION}
  nf-fluab: ${NF_FLUAB_VERSION}
  fluab-reference-db: ${FLUAB_REFERENCE_DB_VERSION}

Reference database:
  Path: ${FLUAB_DB_TARGET}
  Release: $(basename "$FLUAB_DB_TARGET")
EOF

log "Run information: ${RUN_INFO_FILE}"

# ==========================================================
# STEP 1: Run nf-qcflow
# ==========================================================

log "=========================================================="
log "STEP 1: Running nf-qcflow"
log "=========================================================="

run_cmd nextflow run "${NF_QCFLOW_DIR}/main.nf" \
    -profile "$NF_PROFILE" \
    -c "$QCFLOW_CONFIG" \
    --input "$SAMPLESHEET" \
    --outdir "$QC_OUTDIR" \
    -resume

log "nf-qcflow completed successfully."

# ==========================================================
# STEP 2: Check nf-qcflow output samplesheet
# ==========================================================

log "=========================================================="
log "STEP 2: Checking nf-qcflow output samplesheet"
log "=========================================================="

QC_SAMPLESHEET="${QC_OUTDIR}/${QC_OUTPUT_SAMPLESHEET_REL}"

if [[ ! -f "$QC_SAMPLESHEET" ]]; then
    log "ERROR: Downstream samplesheet generated by nf-qcflow was not found:"
    log "       ${QC_SAMPLESHEET}"
    exit 1
fi

log "Samplesheet for nf-fluab: ${QC_SAMPLESHEET}"

# ==========================================================
# STEP 3: Run nf-fluab
# ==========================================================

log "=========================================================="
log "STEP 3: Running nf-fluab"
log "=========================================================="

run_cmd nextflow run "${NF_FLUAB_DIR}/main.nf" \
    -profile "$NF_PROFILE" \
    -c "$FLUAB_CONFIG" \
    --input "$QC_SAMPLESHEET" \
    --database "$FLUAB_DB" \
    --outdir "$FLUAB_OUTDIR" \
    -resume

log "nf-fluab completed successfully."

# ==========================================================
# STEP 4: Generate master report
# ==========================================================

log "=========================================================="
log "STEP 4: Generating master report"
log "=========================================================="

QC_REPORT="${QC_OUTDIR}/report/reads.qcreport.csv"
SUMMARY_REPORT="${FLUAB_OUTDIR}/report/summary_report.csv"
MASTER_REPORT="${MASTER_REPORT_OUTDIR}/master_report.csv"

if [[ ! -f "$QC_REPORT" ]]; then
    log "ERROR: Read QC report not found: ${QC_REPORT}"
    exit 1
fi

if [[ ! -f "$SUMMARY_REPORT" ]]; then
    log "ERROR: Influenza summary report not found: ${SUMMARY_REPORT}"
    exit 1
fi

run_cmd python3 "$MASTER_REPORT_SCRIPT" \
    --summary-report "$SUMMARY_REPORT" \
    --read-qc-report "$QC_REPORT" \
    --nf-qcflow-ver "$NF_QCFLOW_VERSION" \
    --flu-analyzer-ver "$VERSION" \
    --output "$MASTER_REPORT"

if [[ ! -f "$MASTER_REPORT" ]]; then
    log "ERROR: Master report was not generated: ${MASTER_REPORT}"
    exit 1
fi

log "Master report generated: ${MASTER_REPORT}"

# ==========================================================
# Finished
# ==========================================================

log "=========================================================="
log "flu-analyzer completed successfully."
log "=========================================================="
log "Run information: ${RUN_INFO_FILE}"
log "QC results: ${QC_OUTDIR}"
log "Influenza analysis results: ${FLUAB_OUTDIR}"
log "Master report: ${MASTER_REPORT}"
log "Log file: ${LOG_FILE}"
