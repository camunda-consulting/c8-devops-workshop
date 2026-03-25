#!/bin/sh

CAMUNDA_NAMESPACE="default"
CAMUNDA_RELEASE_NAME="camunda"

# Create new Camunda cluster for ES templates
helm install $CAMUNDA_RELEASE_NAME camunda/camunda-platform -f ./camunda-values.yaml -n "$CAMUNDA_NAMESPACE" --wait
echo "Initial Camunda Platform installed successfully for ES templates"

# Create ES snapshot repository
kubectl apply -f ./es-snapshot-minio-job.yaml -n "$CAMUNDA_NAMESPACE"
kubectl wait --for=condition=complete --timeout=600s job/camunda-es-snapshot-minio-job -n "$CAMUNDA_NAMESPACE"
kubectl delete -f ./es-snapshot-minio-job.yaml -n "$CAMUNDA_NAMESPACE"
echo "Elasticsearch snapshot repository created successfully"

# Disable Zeebe & Webapps
helm upgrade $CAMUNDA_RELEASE_NAME camunda/camunda-platform -f ./camunda-values.yaml -f ./restore/camunda-index-restore.yaml -n "$CAMUNDA_NAMESPACE" --wait
echo "Zeebe and Webapps disabled successfully"

# Delete all indices in ES
kubectl apply -f ./restore/es-delete-all-indices.yaml -n "$CAMUNDA_NAMESPACE"
kubectl wait --for=condition=complete --timeout=600s job/camunda-es-delete-all-indices-job -n "$CAMUNDA_NAMESPACE"
kubectl delete -f ./restore/es-delete-all-indices.yaml -n "$CAMUNDA_NAMESPACE"
echo "Elasticsearch indices deleted successfully"

# Restore all snapshots in ES
kubectl apply -f ./restore/es-snapshot-restore-job.yaml -n "$CAMUNDA_NAMESPACE"
kubectl wait --for=condition=complete --timeout=600s job/camunda-es-snapshot-restore-job -n "$CAMUNDA_NAMESPACE"
kubectl delete -f ./restore/es-snapshot-restore-job.yaml -n "$CAMUNDA_NAMESPACE"
echo "Elasticsearch indices restored successfully"

# Delete Zeebe disks
kubectl delete $(kubectl get pvc -o name | grep zeebe) -n "$CAMUNDA_NAMESPACE" --wait
echo "Zeebe disks deleted successfully"

# Restore Zeebe

# Log line to look for (adjust if you use a different marker)
LOG_PATTERN="Successfully restored broker from backup"

# Label selector that matches all Zeebe broker pods in the StatefulSet
ZEEBE_LABEL_SELECTOR="app.kubernetes.io/component=zeebe-broker,app.kubernetes.io/instance=$CAMUNDA_RELEASE_NAME"

# Timeout per pod (seconds)
TIMEOUT_SECONDS_PER_POD=600

wait_for_log_pattern_pod() {
  local namespace="$1"
  local pod_name="$2"
  local pattern="$3"
  local timeout="$4"

  echo "Waiting for log pattern in pod: $pod_name (timeout: ${timeout}s)"

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
      echo "Found log pattern in pod: $pod_name (current logs, restartCount=$restart_count)"
      return 0
    fi

    if kubectl -n "$namespace" logs "$pod_name" --previous 2>/dev/null | grep -qF "$pattern"; then
      local restart_count
      restart_count="$(kubectl -n "$namespace" get pod "$pod_name" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
      echo "Found log pattern in pod: $pod_name (previous logs, restartCount=$restart_count)"
      return 0
    fi

    echo "Pattern not found yet in $pod_name (current or previous logs), retrying in 1s..."
    sleep 1
  done

  echo "Timed out waiting for log pattern in pod: $pod_name"
  echo "Last logs from $pod_name:"
  kubectl -n "$namespace" logs "$pod_name" --tail=20 || true
  return 2
}

wait_for_log_pattern_all_zeebe_pods() {
  local namespace="$1"
  local label_selector="$2"
  local pattern="$3"
  local timeout_per_pod="$4"

  echo "Finding Zeebe broker pods with selector: $label_selector"

  # Get all Zeebe broker pods
  local pods
  pods="$(kubectl -n "$namespace" get pods -l "$label_selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "$pods" ]]; then
    echo "No Zeebe pods found with label selector: $label_selector"
    return 2
  fi

  echo "Found Zeebe pods:"
  echo "$pods" | sed 's/^/  - /'

  # Check each pod sequentially
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    wait_for_log_pattern_pod "$namespace" "$pod" "$pattern" "$timeout_per_pod" || return 2
  done <<< "$pods"

  echo "Log pattern found in all Zeebe pods"
}

helm upgrade $CAMUNDA_RELEASE_NAME camunda/camunda-platform \
  -f ./camunda-values.yaml \
  -f ./restore/camunda-zeebe-restore.yaml \
  -n "$CAMUNDA_NAMESPACE"

wait_for_log_pattern_all_zeebe_pods \
  "$CAMUNDA_NAMESPACE" \
  "$ZEEBE_LABEL_SELECTOR" \
  "$LOG_PATTERN" \
  "$TIMEOUT_SECONDS_PER_POD"

echo "Zeebe restored successfully"

# Return to normal platform state
helm upgrade $CAMUNDA_RELEASE_NAME camunda/camunda-platform -f ./camunda-values.yaml -n "$CAMUNDA_NAMESPACE"
kubectl scale statefulset camunda-zeebe --replicas 0 -n "$CAMUNDA_NAMESPACE"
kubectl scale statefulset camunda-zeebe --replicas 3 -n "$CAMUNDA_NAMESPACE"
kubectl rollout status statefulset camunda-zeebe -n "$CAMUNDA_NAMESPACE"

echo "Camunda restore completed successfully"
