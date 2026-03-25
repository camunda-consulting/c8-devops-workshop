#!/bin/sh

CAMUNDA_NAMESPACE="default"
CAMUNDA_RELEASE_NAME="camunda"

#
# Helper functions
#

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_section() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "═══════════════════════════════════════════════════════════════"
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
      log "Found log pattern in pod: $pod_name (current logs, restartCount=$restart_count)"
      return 0
    fi

    if kubectl -n "$namespace" logs "$pod_name" --previous 2>/dev/null | grep -qF "$pattern"; then
      local restart_count
      restart_count="$(kubectl -n "$namespace" get pod "$pod_name" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
      log "Found log pattern in pod: $pod_name (previous logs, restartCount=$restart_count)"
      return 0
    fi

    log "Pattern not found yet in $pod_name (current or previous logs), retrying in 1s..."
    sleep 1
  done

  log "Timed out waiting for log pattern in pod: $pod_name"
  log "Last logs from $pod_name:"
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
    log "No Zeebe pods found with label selector: $label_selector"
    return 2
  fi

  log "Found Zeebe pods:"
  echo "$pods" | sed 's/^/  - /'

  # Check each pod sequentially
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    wait_for_log_pattern_pod "$namespace" "$pod" "$pattern" "$timeout_per_pod" || return 2
  done <<< "$pods"

  log "Log pattern found in all Zeebe pods"
}

#
# Restore procedure
#

# Create new Camunda cluster for ES templates
log_section "Step 1: Creating Camunda cluster for ES templates"
helm install $CAMUNDA_RELEASE_NAME camunda/camunda-platform -f ./camunda-values.yaml -n "$CAMUNDA_NAMESPACE" --wait
log "Initial Camunda Platform installed successfully for ES templates"

# Create ES snapshot repository
log_section "Step 2: Creating Elasticsearch snapshot repository"
kubectl apply -f ./es-snapshot-minio-job.yaml -n "$CAMUNDA_NAMESPACE"
kubectl wait --for=condition=complete --timeout=600s job/camunda-es-snapshot-minio-job -n "$CAMUNDA_NAMESPACE"
log "Elasticsearch snapshot repository created successfully"

# Disable Zeebe & Webapps
log_section "Step 3: Disabling Zeebe and Webapps"
helm upgrade $CAMUNDA_RELEASE_NAME camunda/camunda-platform \
  -f ./camunda-values.yaml \
  -f ./restore/camunda-index-restore.yaml \
  -n "$CAMUNDA_NAMESPACE" \
  --wait
log "Zeebe and Webapps disabled successfully"

# Delete all indices in ES
log_section "Step 4: Deleting all Elasticsearch indices"
kubectl apply -f ./restore/es-delete-all-indices.yaml -n "$CAMUNDA_NAMESPACE"
kubectl wait --for=condition=complete --timeout=600s job/camunda-es-delete-all-indices-job -n "$CAMUNDA_NAMESPACE"
log "Elasticsearch indices deleted successfully"

# Restore all snapshots in ES
log_section "Step 5: Restoring Elasticsearch snapshots"
kubectl apply -f ./restore/es-snapshot-restore-job.yaml -n "$CAMUNDA_NAMESPACE"
kubectl wait --for=condition=complete --timeout=600s job/camunda-es-snapshot-restore-job -n "$CAMUNDA_NAMESPACE"
log "Elasticsearch indices restored successfully"

# Delete Zeebe disks
log_section "Step 6: Deleting Zeebe persistent volumes claims"
kubectl delete $(kubectl get pvc -o name | grep zeebe) -n "$CAMUNDA_NAMESPACE" --wait
log "Zeebe persistent volumes claims deleted successfully"

# Restore Zeebe
log_section "Step 7: Restoring Zeebe from backup"

LOG_PATTERN="Successfully restored broker from backup"
ZEEBE_LABEL_SELECTOR="app.kubernetes.io/component=zeebe-broker,app.kubernetes.io/instance=$CAMUNDA_RELEASE_NAME"
TIMEOUT_SECONDS_PER_POD=600

helm upgrade $CAMUNDA_RELEASE_NAME camunda/camunda-platform \
  -f ./camunda-values.yaml \
  -f ./restore/camunda-zeebe-restore.yaml \
  -n "$CAMUNDA_NAMESPACE"
wait_for_log_pattern_all_zeebe_pods \
  "$CAMUNDA_NAMESPACE" \
  "$ZEEBE_LABEL_SELECTOR" \
  "$LOG_PATTERN" \
  "$TIMEOUT_SECONDS_PER_POD"
log "Zeebe restored successfully"

# Return to normal platform state
log_section "Step 8: Restoring platform to normal state"
helm upgrade $CAMUNDA_RELEASE_NAME camunda/camunda-platform -f ./camunda-values.yaml -n "$CAMUNDA_NAMESPACE"
REPLICAS="$(kubectl get statefulset $CAMUNDA_RELEASE_NAME-zeebe -n "$CAMUNDA_NAMESPACE" -o jsonpath='{.spec.replicas}')"
kubectl scale statefulset $CAMUNDA_RELEASE_NAME-zeebe --replicas 0 -n "$CAMUNDA_NAMESPACE"
kubectl scale statefulset $CAMUNDA_RELEASE_NAME-zeebe --replicas "$REPLICAS" -n "$CAMUNDA_NAMESPACE"
kubectl rollout status statefulset $CAMUNDA_RELEASE_NAME-zeebe -n "$CAMUNDA_NAMESPACE"
log "Camunda restore completed successfully"

# Cleanup jobs
log_section "Step 9: Cleanup jobs"
kubectl delete -f ./es-snapshot-minio-job.yaml -n "$CAMUNDA_NAMESPACE" --wait
kubectl delete -f ./restore/es-delete-all-indices.yaml -n "$CAMUNDA_NAMESPACE" --wait
kubectl delete -f ./restore/es-snapshot-restore-job.yaml -n "$CAMUNDA_NAMESPACE" --wait
log "Restore jobs cleaned up successfully"

log "Successfully completed restore procedure. Camunda Platform is now running with restored data."
