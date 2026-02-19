# Disaster Simulation - Technical Overview

## Overview

The disaster simulation uses two Kubernetes Jobs to simulate data loss in Camunda Platform:
1. **simulate-disaster.yaml** - Deletes Zeebe broker data
2. **simulate-es-disaster.yaml** - Deletes Elasticsearch indices

## simulate-disaster.yaml (Zeebe Data Deletion)

### Components

**1. ServiceAccount: `zeebe-disaster-simulator`**
- Identity used by the Job pod to authenticate with Kubernetes API

**2. Role: `zeebe-disaster-simulator`**
- Defines permissions needed:
  - `pods`: get, list, watch, delete
  - `pods/exec`: create (for executing commands inside pods)
  - `statefulsets`: get, list, patch, update
  - `statefulsets/scale`: get, update, patch

**3. RoleBinding: `zeebe-disaster-simulator`**
- Binds the ServiceAccount to the Role, granting the permissions

**4. Job: `camunda-simulate-disaster`**
- Runs a `bitnami/kubectl:latest` container with the ServiceAccount
- Container has kubectl installed and can interact with Kubernetes API

### Execution Flow

1. **Discovery Phase:**
   - Uses `kubectl get statefulset -l app.kubernetes.io/component=zeebe-broker` to find Zeebe StatefulSet
   - Gets current replica count from StatefulSet spec

2. **Data Deletion Phase:**
   - Loops through all pods (highest to lowest ordinal: zeebe-2 → zeebe-1 → zeebe-0)
   - For each pod:
     - Uses `kubectl exec <pod> -- sh -c "rm -rf /usr/local/zeebe/data/*"` to delete data
     - The `pods/exec` permission allows creating exec subresources
     - Uses `kubectl exec <pod> -- sh -c "ls -la /usr/local/zeebe/data/"` to verify deletion

3. **Result:**
   - All Zeebe pods have empty data directories
   - Pods remain running (no scaling done by this job)
   - Data directory is mounted volume, so only contents are deleted, not the directory itself

### Key Technical Points

- **Why RBAC?** The Job pod needs permission to interact with Kubernetes API (list StatefulSets, exec into pods)
- **Why highest-to-lowest?** Prepares for potential future enhancement where scaling happens per pod
- **Why not scale?** Keeps disaster simulation focused on data deletion only; scaling is done manually in restore process

## simulate-es-disaster.yaml (Elasticsearch Index Deletion)

### Components

**1. Job: `camunda-simulate-es-disaster`**
- No ServiceAccount needed (doesn't use Kubernetes API)
- Runs a `curlimages/curl` container
- Uses HTTP calls, not Kubernetes API calls

### Execution Flow

1. **Discovery Phase:**
   - Uses `curl` to call Elasticsearch REST API at `http://camunda-elasticsearch:9200`
   - Queries `/_cat/indices?h=index` to get all index names
   - Service name resolution happens via Kubernetes DNS (camunda-elasticsearch.default.svc.cluster.local)

2. **Deletion Phase:**
   - Loops through prefixes: `operate-`, `tasklist-`, `zeebe-record-`
   - For each prefix:
     - Filters index list using `grep`
     - Sends `DELETE` HTTP request to Elasticsearch for each matching index
     - Uses `/_snapshot/` API endpoint
     - Verifies HTTP 200 response

3. **Result:**
   - All Camunda indices are deleted from Elasticsearch
   - Elasticsearch cluster remains running

### Key Technical Points

- **Why no RBAC?** Uses HTTP/REST calls to Elasticsearch, not Kubernetes API
- **Network access:** Pod can resolve service name `camunda-elasticsearch` via cluster DNS
- **Service communication:** Direct pod-to-service HTTP communication within cluster network
- **No kubectl needed:** Pure HTTP client (curl) is sufficient

## Comparison

| Aspect | simulate-disaster.yaml | simulate-es-disaster.yaml |
|--------|------------------------|---------------------------|
| **Target** | Zeebe broker file system | Elasticsearch HTTP API |
| **Access Method** | Kubernetes API (kubectl exec) | HTTP REST API (curl) |
| **RBAC Required** | Yes (ServiceAccount + Role) | No |
| **Image** | bitnami/kubectl | curlimages/curl |
| **Permissions** | Pod exec, StatefulSet access | None (uses service-to-service HTTP) |
| **Network** | Kubernetes API server | Elasticsearch service (port 9200) |

## Why Two Different Approaches?

- **Zeebe:** Stores data in persistent volumes (files). Requires file system access via `kubectl exec`
- **Elasticsearch:** Exposes data management via REST API. Can be managed through HTTP calls without kubectl

Both jobs run in the same namespace as Camunda and leverage Kubernetes service discovery for networking.
