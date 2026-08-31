# Camunda 8.9 — Incremental Restore & Disaster Recovery Workshop

This workshop demonstrates Camunda 8.9 backup/restore against a **warm-standby
DR Elasticsearch cluster**: two ES clusters (`es-main`, `es-dr`) share one
MinIO-backed snapshot repository. `es-dr` is warmed incrementally from
successive backups while `es-main` keeps serving live traffic, then a full
disaster is simulated (`es-main` + Camunda destroyed) and everything is
restored — **incrementally for ES**, **fully for Zeebe**.


## Prerequisites

- A running Kubernetes cluster (`kubectl` pointed at it) with enough headroom
  for: 2 single-node ES clusters, a 3-broker Zeebe cluster + Optimize, MinIO,
  and a continuous load generator. This was run against local `kind` — watch
  host CPU/memory if you're tight on resources
- Helm 3, with these repos added:

```bash
helm repo add camunda https://helm.camunda.io
helm repo add elastic https://helm.elastic.co
helm repo update camunda elastic
```

  (MinIO is pulled via OCI directly, no repo needed.)
- All commands assume your shell is in this directory (`03 - Lab 3 - Backup and Restore/`).
- **Every `kubectl apply -f .../*-job.yaml` below is preceded by a
  `kubectl delete job ... --ignore-not-found`.** Kubernetes `Job` specs are
  immutable — re-applying one that already exists (e.g. running the backup
  job a second time, or retrying a step) fails with a `field is immutable`
  error unless the old `Job` object is deleted first. `--ignore-not-found`
  makes the delete a no-op the very first time, so the same two lines work
  whether it's the first run or a retry.

---

## Section 1 — Set up the environment

Three namespaces, kept separate deliberately: `minio` (object storage),
`es-main-dr` (both ES clusters — same namespace, distinguished by release
name/`clusterName`, so they can share resources realistically), and
`camunda-test` (the actual Camunda deployment).

### 1.1 Create namespaces

```bash
kubectl create namespace minio
kubectl create namespace es-main-dr
kubectl create namespace camunda-test
```

### 1.2 Deploy MinIO

```bash
helm install minio oci://registry-1.docker.io/bitnamicharts/minio -f ./minio-values.yaml -n minio
```

Note: `minio-values.yaml` points the image at the `bitnamilegacy` Docker Hub
org, not the chart's own default (`bitnami/minio`). Bitnami moved most free
image tags behind a paid subscription in August 2025 — the default tags 404
on pull. `bitnamilegacy` still publishes the same tags for free.

### 1.3 Deploy the two Elasticsearch clusters

```bash
helm install es-main elastic/elasticsearch --version 8.5.1 -f ./es-main-values.yaml -n es-main-dr
helm install es-dr elastic/elasticsearch --version 8.5.1 -f ./es-dr-values.yaml -n es-main-dr
```

Both are single-node, no TLS/auth (local training only). Worth knowing before
you wait on a stuck rollout:
    
- Once Camunda's own indices exist (`number_of_replicas: 1` by default), a
  genuine single-node cluster can never assign those replica shards — it's
  permanently `yellow`, which is the *correct* healthy state for this
  topology, not a fault. Both files set
  `clusterHealthCheckParams: "wait_for_status=yellow&timeout=1s"` so the
  readiness probe doesn't wait forever for an unreachable `green`.

Wait for both to be ready:

```bash
kubectl rollout status statefulset/es-main-master -n es-main-dr
kubectl rollout status statefulset/es-dr-master -n es-main-dr
```

### 1.4 Deploy Camunda

```bash
kubectl apply -f ./script-config.yaml -n camunda-test
helm install camunda camunda/camunda-platform --version 14.8.5 -f ./camunda-values.yaml -n camunda-test
```

`script-config.yaml` is a shared ConfigMap every job in this workshop reads
from (`envFrom`) — endpoints, bucket name, repository names, and the mutable
`BACKUP_ID` field used later. It must exist before Camunda installs, since
`camunda-values.yaml` reads several keys from it at pod-start time.

`camunda-values.yaml` points at `es-main`, and also sets:
- `orchestration.security.authentication.unprotectedApi: true` and
  `orchestration.security.authorizations.enabled: false` — local training
  only, so the jobs in this workshop (which don't pass credentials) can call
  the REST/actuator APIs. **Do not use outside of local training.**
- A raw Spring config block (`orchestration.extraConfiguration`) activating
  Zeebe's S3 backup store against MinIO — this is what backups actually
  write to later.

Wait for it to come up:

```bash
kubectl rollout status statefulset/camunda-zeebe -n camunda-test
kubectl rollout status deployment/camunda-optimize -n camunda-test
```

---

## Section 2 — Generate data (batch 1)

### 2.1 Deploy the benchmark process

```bash
kubectl create configmap models --from-file=BenchmarkProcess.bpmn=./backup/BenchmarkProcess.bpmn -n camunda-test
kubectl label configmap models type=camunda-backup-restore -n camunda-test
kubectl delete job camunda-deploy-process -n camunda-test --ignore-not-found
kubectl apply -f ./backup/deploy-process-job.yaml -n camunda-test
kubectl logs -f job/camunda-deploy-process -n camunda-test
```

You should see a JSON response with a `deploymentKey` and the
`BenchmarkProcess` definition.

### 2.2 Start the load generator

```bash
kubectl create configmap payload --from-file=./backup/payload.json -n camunda-test
kubectl label configmap payload type=camunda-backup-restore -n camunda-test
kubectl apply -f ./backup/benchmark.yaml -n camunda-test
```

This deploys [camunda-8-benchmark](https://github.com/camunda-community-hub/camunda-8-benchmark)
as a continuously-running `Deployment` (not a one-shot job) — it keeps
creating and completing `BenchmarkProcess` instances at a configurable rate,
adapting to backpressure. Confirm it's actually producing instances (not just
running):

```bash
kubectl logs -l app=benchmark -n camunda-test --tail=20
```

Let it run for at least a minute or two before taking the first backup, so
there's real data to back up.

---

## Section 3 — Backup #1

### 3.1 Register the snapshot repositories on es-main

```bash
kubectl delete job camunda-es-snapshot-minio-job -n camunda-test --ignore-not-found
kubectl apply -f ./backup/es-snapshot-minio-job.yaml -n camunda-test
kubectl logs -f job/camunda-es-snapshot-minio-job -n camunda-test
```

Registers three S3 (MinIO-backed) repositories on `es-main`:
`orchestration-backup`, `optimize-backup`, `zeebe-records-backup` (the exact
names live in `script-config.yaml`).

### 3.2 Trigger the backup

```bash
kubectl delete job camunda-create-backup -n camunda-test --ignore-not-found
kubectl apply -f ./backup/create-backup-job.yaml -n camunda-test
kubectl logs -f job/camunda-create-backup -n camunda-test
```

**Note the backup ID printed in the logs** (a Unix timestamp, e.g.
`1787936992`) — you'll need it for every restore step below.

This one job does **four** distinct things under that one shared ID:

1. **Optimize's own backup** — `POST .../actuator/backups` — Optimize's own
   ES indices (analytics/reporting).
2. **Operate/Tasklist's webapp ES indices** — `POST .../actuator/backupHistory`
   — Operate + Tasklist + Admin/Identity indices
3. **Raw `zeebe-record_*` ES indices** — direct ES snapshot call — the
   legacy zeebe exporters, which Optimize's importer reads from.
4. **Zeebe broker's own runtime state** — `POST .../actuator/backupRuntime`
   — the actual engine data (RocksDB/partitions), restored fully later.

The exporter is soft-paused for the whole sequence so all four pieces reflect
one consistent point in time.

---

## Section 4 — Warm the DR cluster (incremental restore, part 1)

This is the core teaching point: restore backup #1's **ES data only** onto
`es-dr`, while `es-main`/Camunda keep running untouched. Later, when backup
#2 restores on top of this, only the *changed* segments transfer — that's
what makes it incremental.

### 4.1 Register the same repositories on es-dr — READ-ONLY

```bash
kubectl delete job camunda-es-snapshot-minio-job-dr -n camunda-test --ignore-not-found
kubectl apply -f ./restore/es-snapshot-minio-job-dr.yaml -n camunda-test
kubectl logs -f job/camunda-es-snapshot-minio-job-dr -n camunda-test
```

**This must be `"readonly": true`** (already set in the file) — this is not
optional. Registering the *same* S3 repository as writable on a second
cluster makes that cluster cache the repository's contents at registration
time; snapshots written afterward by the other cluster's backup job silently
never appear, no error. Confirmed live: this exact failure happened, and
switching to `readonly: true` fixed it immediately (Elastic's own docs:
read-only registration "prevents Elasticsearch from caching the repository's
contents, which means changes made by other clusters become visible
straight away"). `es-dr` never needs to *write* to this repo anyway, so
there's no downside.

### 4.2 Set the backup ID and restore

```bash
# Edit script-config.yaml: set BACKUP_ID to the ID from step 3.2, e.g.:
#   BACKUP_ID: "1787936992"
kubectl apply -f ./script-config.yaml -n camunda-test

kubectl delete job camunda-es-restore -n camunda-test --ignore-not-found
kubectl apply -f ./restore/es-restore-job.yaml -n camunda-test
kubectl logs -f job/camunda-es-restore -n camunda-test
```

For each of the three repos, this job finds the snapshot(s) matching
`$BACKUP_ID`, reads the exact index list each one actually contains (not a
guessed pattern), **closes** those indices if present
(`ignore_unavailable=true` — a no-op on this first run since `es-dr` starts
empty), then restores. Deliberately does **not** touch `backupRuntime`
(Zeebe's own data) — that's a separate mechanism, restored later on fresh
PVCs, not an ES operation.

---

## Section 5 — Generate more data, take backup #2

The load generator from Section 2.2 should still be running, continuously
creating instances. If you stopped it, restart it:

```bash
kubectl apply -f ./backup/benchmark.yaml -n camunda-test
```

Let it run a while longer, then repeat the backup:

```bash
kubectl delete job camunda-create-backup -n camunda-test --ignore-not-found
kubectl apply -f ./backup/create-backup-job.yaml -n camunda-test
kubectl logs -f job/camunda-create-backup -n camunda-test
```

Note this **second** backup ID (e.g. `1787940965`) — it's the one you'll
restore from after the disaster.

---

## Section 6 — Simulate the disaster

Destroys the main region: Camunda (Zeebe + Optimize) and `es-main`, including
their PVCs. `es-dr` and MinIO are left completely untouched — that's the
whole point of the warm standby.

```bash
kubectl delete -f ./backup/benchmark.yaml -n camunda-test --ignore-not-found

helm uninstall camunda -n camunda-test
helm uninstall es-main -n es-main-dr

kubectl delete pvc data-camunda-zeebe-0 data-camunda-zeebe-1 data-camunda-zeebe-2 -n camunda-test
kubectl delete pvc es-main-master-es-main-master-0 -n es-main-dr
```

The `benchmark` load generator is a plain `Deployment` applied directly with
`kubectl` — it's **not** part of the `camunda` Helm release, so
`helm uninstall camunda` never touches it. Left running, it just crash-loops
forever against a gateway that no longer exists (confirmed live: DNS
resolution failure for `camunda-zeebe-gateway`) — harmless but noisy, and a
needless resource drain on top of everything else running. Delete it
explicitly, as above, before moving on.

Verify the blast radius is exactly what you expect before continuing:

```bash
kubectl get pods,pvc -n camunda-test     # only completed job pods should remain
kubectl get pods,pvc -n es-main-dr       # only es-dr should remain, Running, PVC Bound
kubectl get pods,pvc -n minio            # fully untouched
```

---

## Section 7 — Restore (incremental ES + full Zeebe)

### 7.1 Restore backup #2's ES data onto es-dr (incremental, part 2)

```bash
# Edit script-config.yaml: set BACKUP_ID to backup #2's ID, e.g.:
#   BACKUP_ID: "1787940965"
kubectl apply -f ./script-config.yaml -n camunda-test

kubectl delete job camunda-es-restore -n camunda-test --ignore-not-found
kubectl apply -f ./restore/es-restore-job.yaml -n camunda-test
kubectl logs -f job/camunda-es-restore -n camunda-test
```

Same job as Section 4.2, same script, no changes needed — `es-dr` already has
backup #1's indices open (not empty) this time, so close→restore only
transfers what changed since then. Confirmed live: ~65-70% of shard bytes
were *reused*, not re-transferred, on the largest index — that's the
incremental mechanic actually happening, verifiable via
`GET <index>/_recovery`.

### 7.2 Restore Zeebe (full) and stand Camunda back up on es-dr

`restore/camunda-values-failover.yaml` is a standalone copy of
`camunda-values.yaml` pointed at `es-dr` instead of the now-destroyed
`es-main` — used *instead of* the base file, which stays untouched/reusable
for running this whole workshop again from scratch.
`restore/camunda-zeebe-restore-values.yaml` layers on top of it for the
one-time restore pass only.

```bash
helm install camunda camunda/camunda-platform --version 14.8.5 \
  -f ./restore/camunda-values-failover.yaml \
  -f ./restore/camunda-zeebe-restore-values.yaml \
  -n camunda-test
```

Watch it — this is expected to look alarming at first:

```bash
kubectl get pods -n camunda-test -w
```

The orchestration pods will cycle through `Running`/`Error`/`CrashLoopBackOff`.
That's normal: `ZEEBE_RESTORE=true` makes the container run
`restore --backupId=...` instead of starting the broker — a one-shot command
that exits when done, and since `restartPolicy: Always` is mandatory for
StatefulSet pods, kubelet just restarts it (attempting the restore again,
which now correctly fails with "directory not empty" — the previous attempt
already succeeded). Confirm the restore actually completed by checking the
data directly rather than trusting the log narrative:

```bash
kubectl exec camunda-zeebe-0 -n camunda-test -- du -sh /usr/local/camunda/data/raft-partition
```

Real restored data looks like tens-of-MB with genuine `.sst`/`zeebe.metadata`
files, not an empty skeleton. Once confirmed for all 3 broker pods, switch
back to normal operation:

```bash
helm upgrade camunda camunda/camunda-platform --version 14.8.5 \
  -f ./restore/camunda-values-failover.yaml \
  -n camunda-test
```

This drops `ZEEBE_RESTORE`/`ZEEBE_RESTORE_FROM_BACKUP_ID` (Helm replaces,
rather than merges, list-type values like `orchestration.env` across layered
`-f` files) and re-enables Optimize (disabled during the restore pass to
minimize moving parts while the broker was mid-restore).

**Known StatefulSet quirk to watch for:** the rolling update from
restore-mode back to normal can get stuck — a pod deleted or recreated
out of its normal update turn can come back on the *old* (still
restore-mode) revision, which then crash-loops forever and can deadlock a
sibling pod waiting on Raft quorum. If you see this (check
`kubectl get pods -n camunda-test -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.controller-revision-hash}{"\n"}{end}'`
and find mismatched revisions with a pod stuck in `CrashLoopBackOff`), the
fix that worked live was scaling to 0 and back — this only recreates pods,
the PVCs (with the already-restored data) are untouched:

```bash
kubectl scale statefulset camunda-zeebe --replicas=0 -n camunda-test
# wait for 0 pods, then:
kubectl scale statefulset camunda-zeebe --replicas=3 -n camunda-test
```

Verify the cluster is genuinely healthy afterward:

```bash
kubectl get pods -n camunda-test -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.controller-revision-hash}{"\n"}{end}'
# all three zeebe pods should show the SAME revision hash
```

---

## Section 8 — Validate

Confirm the cluster is genuinely healthy and serving the restored data:

```bash
kubectl run curltest --image=curlimages/curl -n camunda-test --restart=Never --command -- sleep 30
kubectl wait --for=condition=ready pod/curltest -n camunda-test --timeout=20s

# Cluster topology — 3 brokers, each partition should have a healthy leader
kubectl exec curltest -n camunda-test -- curl -s "http://camunda-zeebe-gateway:8080/v2/topology"

# Process instance history — should include instances from BOTH batches (before and after the disaster)
kubectl exec curltest -n camunda-test -- curl -s -X POST "http://camunda-zeebe-gateway:8080/v2/process-instances/search" \
  -H 'Content-Type: application/json' -d '{"filter":{"state":"COMPLETED"}}'

kubectl delete pod curltest -n camunda-test
```

---

## Section 9 — Cleanup

```bash
kubectl delete -f ./backup/benchmark.yaml -n camunda-test --ignore-not-found

helm uninstall camunda -n camunda-test
helm uninstall es-dr -n es-main-dr
helm uninstall minio -n minio

kubectl delete pvc --all -n camunda-test
kubectl delete pvc --all -n es-main-dr
kubectl delete pvc --all -n minio

kubectl delete configmap models payload camunda-script-config -n camunda-test --ignore-not-found
kubectl delete job,pod -l type=camunda-backup-restore -n camunda-test --ignore-not-found

kubectl delete namespace es-main-dr minio camunda-test
```

Notes:
- `es-main` and its PVC no longer exist by this point — already destroyed in
  Section 6.
