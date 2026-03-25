#!/bin/bash
################################################################################
# Script: restore-backup-ai-improved.sh
#
# Purpose: Restore Camunda Platform from Elasticsearch backup stored in Minio
#
# Prerequisites:
#   - kubectl configured and authenticated with target cluster
#   - helm installed and configured (Camunda Helm repository added)
#   - Minio snapshot repository preconfigured in backup values file
#   - YAML configuration files in restore/ directory
#
# Usage: ./restore-backup-ai-improved.sh -n <namespace> [OPTIONS]
#
# Options:
#   -n, --namespace <namespace>       Kubernetes namespace (required)
#   -r, --helm-release <name>         Helm release name (default: camunda)
#   -t, --timeout <seconds>           Timeout per operation (default: 600)
#   -h, --help                        Show this help message
#
# Examples:
#   ./restore-backup-ai-improved.sh -n production
#   ./restore-backup-ai-improved.sh -n default -r my-camunda -t 900
#
# Exit Codes:
#   0   - Restore completed successfully
#   1   - Invalid arguments or prerequisites not met
#   2   - Restore operation failed
#
################################################################################

set -euo pipefail

#
# Configuration & Constants
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Default values (can be overridden via CLI options or environment variables)
CAMUNDA_NAMESPACE=""
CAMUNDA_RELEASE_NAME="${CAMUNDA_RELEASE_NAME:-camunda}"
TIMEOUT_SECONDS=600
readonly LOG_PATTERN="Successfully restored broker from backup"
readonly ZEEBE_LABEL_SELECTOR="app.kubernetes.io/component=zeebe-broker,app.kubernetes.io/instance"

# Configuration files (relative to script directory)
readonly CAMUNDA_VALUES_FILE="${SCRIPT_DIR}/../camunda-values.yaml"
readonly ES_SNAPSHOT_MINIO_JOB="${SCRIPT_DIR}/../es-snapshot-minio-job.yaml"
readonly INDEX_RESTORE_VALUES="${SCRIPT_DIR}/camunda-index-restore.yaml"
readonly ES_DELETE_INDICES_JOB="${SCRIPT_DIR}/es-delete-all-indices.yaml"
readonly ES_SNAPSHOT_RESTORE_JOB="${SCRIPT_DIR}/es-snapshot-restore-job.yaml"
readonly ZEEBE_RESTORE_VALUES="${SCRIPT_DIR}/camunda-zeebe-restore.yaml"

#
# Logging Functions
#

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_warn() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*"
}

log_success() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $*"
}

log_section() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "═══════════════════════════════════════════════════════════════"
}

#
# Validation Functions
#

check_prerequisites() {
  log "Checking prerequisites..."

  local required_commands=("kubectl" "helm")
  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd is not installed or not in PATH"
      return 1
    fi
  done

  log_success "All prerequisites met"
}

check_file_exists() {
  local file="$1"
  local description="${2:-File}"

  if [[ ! -f "$file" ]]; then
    log_error "$description not found: $file"
    return 1
  fi
}

validate_all_files() {
  log "Validating configuration files..."

  check_file_exists "$CAMUNDA_VALUES_FILE" "Camunda values file" || return 1
  check_file_exists "$ES_SNAPSHOT_MINIO_JOB" "ES snapshot Minio job file" || return 1
  check_file_exists "$INDEX_RESTORE_VALUES" "Index restore values file" || return 1
  check_file_exists "$ES_DELETE_INDICES_JOB" "ES delete indices job file" || return 1
  check_file_exists "$ES_SNAPSHOT_RESTORE_JOB" "ES snapshot restore job file" || return 1
  check_file_exists "$ZEEBE_RESTORE_VALUES" "Zeebe restore values file" || return 1

  log_success "All configuration files present"
}

validate_namespace() {
  log "Validating namespace: $CAMUNDA_NAMESPACE"

  if ! kubectl get namespace "$CAMUNDA_NAMESPACE" &>/dev/null; then
    log_error "Namespace does not exist: $CAMUNDA_NAMESPACE"
    return 1
  fi

  log_success "Namespace is valid"
}

validate_helm_release() {
  log "Validating Helm release: $CAMUNDA_RELEASE_NAME"

  if ! helm list -n "$CAMUNDA_NAMESPACE" | grep -q "^$CAMUNDA_RELEASE_NAME"; then
    log_error "Helm release not found: $CAMUNDA_RELEASE_NAME in namespace $CAMUNDA_NAMESPACE"
    return 1
  fi

  log_success "Helm release exists"
}

validate_inputs() {

  if [[ -z "$CAMUNDA_NAMESPACE" ]]; then
    log_error "Namespace is required"
    return 1
  fi

  if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( TIMEOUT_SECONDS < 60 )); then
    log_error "Timeout must be a positive number >= 60"
    return 1
  fi

  validate_namespace
  validate_all_files
}

#
# Kubernetes Helper Functions
#

wait_for_job_completion() {
  local job_name="$1"
  local namespace="$2"
  local timeout="${3:-600}"

  log "Waiting for job to complete: $job_name (timeout: ${timeout}s)"

  if kubectl wait --for=condition=complete --timeout="${timeout}s" \
    job/"$job_name" -n "$namespace" &>/dev/null; then
    log_success "Job completed: $job_name"
    return 0
  else
    log_error "Job failed or timed out: $job_name"
    # Print job logs for debugging
    log_error "Job logs:"
    kubectl logs -n "$namespace" -l job-name="$job_name" --tail=50 || true
    return 2
  fi
}

wait_for_log_pattern_pod() {
  local namespace="$1"
  local pod_name="$2"
  local pattern="$3"
  local timeout="$4"

  log "Waiting for log pattern in pod: $pod_name (timeout: ${timeout}s)"

  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    # Always check BOTH current and previous logs on every iteration.
    # This avoids missing the pattern when the restore container completes
    # and the pod restarts faster than the polling interval (1s).
    #
    # Scenario A: pod is still in restore mode  → pattern is in current logs
    # Scenario B: restore done, pod restarted   → pattern is in previous logs
    if kubectl -n "$namespace" logs "$pod_name" 2>/dev/null | grep -qF "$pattern"; then
      local restart_count
      restart_count="$(kubectl -n "$namespace" get pod "$pod_name" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
      log_success "Found log pattern in pod: $pod_name (current logs, restartCount=$restart_count)"
      return 0
    fi

    if kubectl -n "$namespace" logs "$pod_name" --previous 2>/dev/null | grep -qF "$pattern"; then
      local restart_count
      restart_count="$(kubectl -n "$namespace" get pod "$pod_name" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
      log_success "Found log pattern in pod: $pod_name (previous logs, restartCount=$restart_count)"
      return 0
    fi

    log_warn "Pattern not found yet in $pod_name (current or previous logs), retrying in 1s..."
    sleep 1
  done

  log_error "Timed out waiting for log pattern in pod: $pod_name"
  log_error "Last logs from $pod_name:"
  kubectl -n "$namespace" logs "$pod_name" --tail=20 || true
  return 2
}

wait_for_log_pattern_all_zeebe_pods() {
  local namespace="$1"
  local label_selector="$2"
  local pattern="$3"
  local timeout_per_pod="$4"

  log "Finding Zeebe broker pods with selector: $label_selector"

  # Get all Zeebe broker pods
  local pods
  pods="$(kubectl -n "$namespace" get pods -l "$label_selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "$pods" ]]; then
    log_error "No Zeebe pods found with label selector: $label_selector"
    return 2
  fi

  log "Found Zeebe pods:"
  echo "$pods" | sed 's/^/  - /'

  # Check each pod sequentially
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    wait_for_log_pattern_pod "$namespace" "$pod" "$pattern" "$timeout_per_pod" || return 2
  done <<< "$pods"

  log_success "Log pattern found in all Zeebe pods"
}

#
# Restore Step Functions
#

step_install_camunda_cluster() {
  log_section "Step 1: Creating Camunda cluster for ES templates"

  helm install "$CAMUNDA_RELEASE_NAME" camunda/camunda-platform \
    -f "$CAMUNDA_VALUES_FILE" \
    -n "$CAMUNDA_NAMESPACE" \
    --wait \
    --timeout=10m

  log_success "Camunda Platform installed successfully"
}

step_create_es_snapshot_repository() {
  log_section "Step 2: Creating Elasticsearch snapshot repository"

  kubectl apply -f "$ES_SNAPSHOT_MINIO_JOB" -n "$CAMUNDA_NAMESPACE"

  wait_for_job_completion "camunda-es-snapshot-minio-job" "$CAMUNDA_NAMESPACE" "$TIMEOUT_SECONDS"

  kubectl delete -f "$ES_SNAPSHOT_MINIO_JOB" -n "$CAMUNDA_NAMESPACE"

  log_success "Elasticsearch snapshot repository created"
}

step_disable_zeebe_webapps() {
  log_section "Step 3: Disabling Zeebe and Webapps for restore"

  helm upgrade "$CAMUNDA_RELEASE_NAME" camunda/camunda-platform \
    -f "$CAMUNDA_VALUES_FILE" \
    -f "$INDEX_RESTORE_VALUES" \
    -n "$CAMUNDA_NAMESPACE" \
    --wait \
    --timeout=10m

  log_success "Zeebe and Webapps disabled"
}

step_delete_es_indices() {
  log_section "Step 4: Deleting all Elasticsearch indices"

  kubectl apply -f "$ES_DELETE_INDICES_JOB" -n "$CAMUNDA_NAMESPACE"

  wait_for_job_completion "camunda-es-delete-all-indices-job" "$CAMUNDA_NAMESPACE" "$TIMEOUT_SECONDS"

  kubectl delete -f "$ES_DELETE_INDICES_JOB" -n "$CAMUNDA_NAMESPACE"

  log_success "Elasticsearch indices deleted"
}

step_restore_es_snapshots() {
  log_section "Step 5: Restoring Elasticsearch snapshots"

  kubectl apply -f "$ES_SNAPSHOT_RESTORE_JOB" -n "$CAMUNDA_NAMESPACE"

  wait_for_job_completion "camunda-es-snapshot-restore-job" "$CAMUNDA_NAMESPACE" "$TIMEOUT_SECONDS"

  kubectl delete -f "$ES_SNAPSHOT_RESTORE_JOB" -n "$CAMUNDA_NAMESPACE"

  log_success "Elasticsearch indices restored"
}

step_delete_zeebe_disks() {
  log_section "Step 6: Deleting Zeebe persistent volumes (disks)"

  log "Fetching Zeebe PVCs..."
  local pvc_list
  pvc_list="$(kubectl get pvc -n "$CAMUNDA_NAMESPACE" -o name | grep zeebe || true)"

  if [[ -z "$pvc_list" ]]; then
    log_warn "No Zeebe PVCs found, skipping deletion"
    return 0
  fi

  log "PVCs to delete: $pvc_list"

  # shellcheck disable=SC2086
  kubectl delete $pvc_list -n "$CAMUNDA_NAMESPACE" --wait

  log_success "Zeebe disks deleted"
}

step_restore_zeebe() {
  log_section "Step 7: Restoring Zeebe from backup"

  helm upgrade "$CAMUNDA_RELEASE_NAME" camunda/camunda-platform \
    -f "$CAMUNDA_VALUES_FILE" \
    -f "$ZEEBE_RESTORE_VALUES" \
    -n "$CAMUNDA_NAMESPACE" \
    --timeout=10m

  # Construct label selector dynamically with the actual Helm release name
  local zeebe_label_selector="${ZEEBE_LABEL_SELECTOR}=${CAMUNDA_RELEASE_NAME}"

  wait_for_log_pattern_all_zeebe_pods \
    "$CAMUNDA_NAMESPACE" \
    "$zeebe_label_selector" \
    "$LOG_PATTERN" \
    "$TIMEOUT_SECONDS"

  log_success "Zeebe restored successfully"
}

step_restore_platform_state() {
  log_section "Step 8: Restoring platform to normal state"

  helm upgrade "$CAMUNDA_RELEASE_NAME" camunda/camunda-platform \
    -f "$CAMUNDA_VALUES_FILE" \
    -n "$CAMUNDA_NAMESPACE" \
    --timeout=10m

  local zeebe_statefulset="${CAMUNDA_RELEASE_NAME}-zeebe"

  # Get current replica count before scaling down so we restore the same number
  local replicas
  replicas="$(kubectl get statefulset "$zeebe_statefulset" \
    -n "$CAMUNDA_NAMESPACE" \
    -o jsonpath='{.spec.replicas}')"

  log "Cycling Zeebe StatefulSet replicas (current: $replicas) to force a clean restart..."

  kubectl scale statefulset "$zeebe_statefulset" \
    --replicas=0 \
    -n "$CAMUNDA_NAMESPACE"

  kubectl scale statefulset "$zeebe_statefulset" \
    --replicas="$replicas" \
    -n "$CAMUNDA_NAMESPACE"

  log "Waiting for Zeebe StatefulSet rollout to complete..."
  kubectl rollout status statefulset "$zeebe_statefulset" \
    -n "$CAMUNDA_NAMESPACE" \
    --timeout=10m

  log_success "Platform restored to normal state"
}

#
# Error Handling
#

cleanup_on_error() {
  local exit_code=$?
  # Only log error if exit code is non-zero (actual error)
  if [[ $exit_code -ne 0 ]]; then
    log_error "Script failed with exit code $exit_code on line $LINENO"
    log_error "Please check the logs above for details"
  fi
  exit "$exit_code"
}

#
# Help Function
#

show_help() {
  head -n 30 "$0" | tail -n +2 | sed 's/^# //'
}

#
# Main Function
#

main() {
  log "Starting Camunda restore process..."
  log "Script: $SCRIPT_NAME, Release: $CAMUNDA_RELEASE_NAME, Namespace: $CAMUNDA_NAMESPACE"

  # Validate all inputs and prerequisites
  check_prerequisites || return 1
  validate_inputs || return 1

  # Execute restore steps
  step_install_camunda_cluster
  step_create_es_snapshot_repository
  step_disable_zeebe_webapps
  step_delete_es_indices
  step_restore_es_snapshots
  step_delete_zeebe_disks
  step_restore_zeebe
  step_restore_platform_state

  log_section "✓ RESTORE COMPLETED SUCCESSFULLY"
  log_success "Camunda Platform restored successfully"
  log_success "Namespace: $CAMUNDA_NAMESPACE"
  log_success "Helm Release: $CAMUNDA_RELEASE_NAME"
}

#
# Argument Parsing
#

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        CAMUNDA_NAMESPACE="$2"
        shift 2
        ;;
      -r|--helm-release)
        CAMUNDA_RELEASE_NAME="$2"
        shift 2
        ;;
      -t|--timeout)
        TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        show_help
        return 1
        ;;
    esac
  done
}

#
# Script Entry Point
#

# Set error trap
trap cleanup_on_error EXIT

# Parse arguments
parse_arguments "$@" || exit 1

# Run main function
main "$@"

exit 0

