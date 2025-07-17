# Trigger Backup and Restore

## Apply shared script config

We will use a shared script config.

```bash
kubectl apply -f ./script-config.yaml
```

## Create Demo Environment

### Create Minio

```bash
helm install minio oci://registry-1.docker.io/bitnamicharts/minio -f ./minio-values.yaml
```

### Install Camunda

```bash
helm install camunda camunda/camunda-platform -f ./camunda-values.yaml
```

### Wait for ES to be ready

```bash
kubectl rollout status sts/camunda-elasticsearch-master
```

### Register Snapshot Repositories

```bash
kubectl apply -f ./es-snapshot-minio-job.yaml
```

```bash
kubectl logs -f $(kubectl get pods --selector=job-name=camunda-es-snapshot-minio-job --output=jsonpath='{.items[*].metadata.name}' | awk '{print $1}') 
```

When it is complete, you can delete the job:

```bash
kubectl delete -f ./es-snapshot-minio-job.yaml
```

### Generate Data

```bash
kubectl create configmap models --from-file=CamundaProcess.bpmn=./backup/BenchmarkProcess.bpmn
kubectl label configmap models type=camunda-backup-restore
```

```bash
kubectl apply -f ./backup/zbctl-deploy-job.yaml 
```

```bash
kubectl logs -f $(kubectl get pods --selector=job-name=camunda-zbctl-deploy --output=jsonpath='{.items[*].metadata.name}' | awk '{print $1}') 
```

```bash
kubectl create configmap payload --from-file=./backup/payload.json
kubectl label configmap payload type=camunda-backup-restore
```

```bash
kubectl apply -f ./backup/benchmark.yaml && sleep 30 && kubectl delete -f ./backup/benchmark.yaml
```

### Review Current State

![Screenshot Operate](images/operate-overview.png)

## Perform Backup

```bash
kubectl apply -f ./backup/create-backup.yaml
```

```bash
kubectl logs -f $(kubectl get pods --selector=job-name=camunda-create-backup --output=jsonpath='{.items[*].metadata.name}' | awk '{print $1}') 
```

As soon as the backup is complete, you can delete the job

```bash
kubectl delete -f ./backup/create-backup.yaml
```

## Simulate Data Loss

```bash
helm delete camunda
```

```bash
kubectl delete pvc data-camunda-elasticsearch-master-0 data-camunda-elasticsearch-master-1 data-camunda-postgresql-0 data-camunda-zeebe-0 data-camunda-zeebe-1 data-camunda-zeebe-2
```

## Restore

### Create New Camunda Cluster

```bash
helm install camunda camunda/camunda-platform -f ./camunda-values.yaml
```

```bash
kubectl rollout status deploy/camunda-operate
```

Why? Templates and Aliases are created again.

### Verify that Templates are generated

![Templates](images/kibana-templates.png)

### Register ES Repositories again

```bash
kubectl apply -f ./es-snapshot-minio-job.yaml
```

```bash
kubectl logs -f $(kubectl get pods --selector=job-name=es-snapshot-minio-job --output=jsonpath='{.items[*].metadata.name}' | awk '{print $1}') 
```

When it is complete, you can delete the job:

```bash
kubectl delete -f ./es-snapshot-minio-job.yaml
```

### Find a backup to restore from

```bash
kubectl apply -f ./restore/find-backup.yaml
```

```bash
kubectl logs -f $(kubectl get pods --selector=job-name=camunda-find-backup --output=jsonpath='{.items[*].metadata.name}' | awk '{print $1}') 
```

Set the backup id you want to restore from to the `scamunda-script-config` and apply it again:

```bash
kubectl apply -f ./script-config.yaml
```

When this is done, you can delete the job:

```bash
kubectl delete -f ./restore/find-backup.yaml
```

### Disable Zeebe & Webapps

```bash
helm upgrade camunda camunda/camunda-platform -f ./camunda-values.yaml -f ./restore/camunda-index-restore.yaml
```

### Delete all Indices

```bash
kubectl apply -f ./restore/es-delete-all-indices.yaml
```

### Restore Snapshots

```bash
kubectl apply -f ./restore/es-snapshot-restore-job.yaml
```

### Delete Zeebe disk

```bash
kubectl delete $(kubectl get pvc -o name | grep zeebe)
```

### Restore Zeebe

```bash
helm upgrade camunda camunda/camunda-platform -f ./camunda-values.yaml -f ./restore/camunda-zeebe-restore.yaml
```

### Return to normal platform state

```bash
helm upgrade camunda camunda/camunda-platform -f ./camunda-values.yaml
```

## Validate Restore

### Operate

![Screenshot Operate](images/operate-overview.png)

### Zeebe

#### Find an active Instance

![Active Instance Operate](images/active-instance-operate.png)

#### Cancel it via Operate UI

![Cancel Instance Operate](images/cancel-instance-operate1.png)

#### Validate Cancellation

![Active Instance Operate](images/cancel-instance-operate2.png)

## Cleanup

```bash
helm uninstall camunda
```

```bash
helm uninstall minio
```

```bash
kubectl delete all -l type=camunda-backup-restore
```

```bash
kubectl delete pvc -l app.kubernetes.io/instance=camunda
```
