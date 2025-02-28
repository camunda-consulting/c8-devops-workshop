#!/bin/bash

TEMPLATE_FILE="zeebe-restore-template.yaml"
JOB_NAME="zeebe-restore-job"
HELM_RELEASE="camunda"
NAMESPACE="default"

CLUSTER_SIZE=3
JOB_NAME="zeebe-restore-job"
IMAGE="camunda/zeebe:8.5.7"
BACKUP_ID="12345"
S3_BUCKETNAME="zeebe-backup"
S3_ENDPOINT="http://minio:9000"
S3_ACCESSKEY="minioadmin"
S3_SECRET="minioadmin"
S3_REGION="us-east-1"
PARTITIONCOUNT="3"
REPLICATIONFACTOR="3"
CLAIM_NAME="data-camunda-zeebe"

fetch_helm_values() {
    if [[ -n "$HELM_RELEASE" && -n "$NAMESPACE" ]]; then
        echo "Fetching values from Helm release: $HELM_RELEASE in namespace: $NAMESPACE"
        HELM_VALUES=$(helm get values "$HELM_RELEASE" -n "$NAMESPACE" --all -o json | jq '.zeebe')
        CLUSTER_SIZE=$(echo "$HELM_VALUES" | jq -r '.clusterSize')
        IMAGE="$(echo "$HELM_VALUES" | jq -r '.image.repository'):$(echo "$HELM_VALUES" | jq -r '.image.tag')"
        PARTITIONCOUNT=$(echo "$HELM_VALUES" | jq -r '.partitionCount')
        REPLICATIONFACTOR=$(echo "$HELM_VALUES" | jq -r '.replicationFactor')
        S3_BUCKETNAME=$(echo "$HELM_VALUES" | jq -r '.env[] | select(.name=="ZEEBE_BROKER_DATA_BACKUP_S3_BUCKETNAME").value')
        S3_ENDPOINT=$(echo "$HELM_VALUES" | jq -r '.env[] | select(.name=="ZEEBE_BROKER_DATA_BACKUP_S3_ENDPOINT").value')
        S3_ACCESSKEY=$(echo "$HELM_VALUES" | jq -r '.env[] | select(.name=="ZEEBE_BROKER_DATA_BACKUP_S3_ACCESSKEY").value')
        S3_SECRET=$(echo "$HELM_VALUES" | jq -r '.env[] | select(.name=="ZEEBE_BROKER_DATA_BACKUP_S3_SECRETKEY").value')
        S3_REGION=$(echo "$HELM_VALUES" | jq -r '.env[] | select(.name=="ZEEBE_BROKER_DATA_BACKUP_S3_REGION").value')
        CLAIM_NAME="data-${HELM_RELEASE}-zeebe"
    fi
}


fetch_helm_values

# Check if template file exists
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "Error: Template file '$TEMPLATE_FILE' not found!"
    exit 1
fi

# Generate job YAML files
for ((i=0; i<CLUSTER_SIZE; i++)); do
    OUTPUT_FILE="zeebe-restore-job-${i}.yaml"
    sed \
        -e "s/{{JOB_NAME}}/zeebe-restore-job-${i}/g" \
        -e "s|{{IMAGE}}|$IMAGE|g" \
        -e "s|{{BACKUP_ID}}|$BACKUP_ID|g" \
        -e "s|{{PARTITIONCOUNT}}|$PARTITIONCOUNT|g" \
        -e "s|{{CLUSTERSIZE}}|$CLUSTER_SIZE|g" \
        -e "s|{{REPLICATIONFACTOR}}|$REPLICATIONFACTOR|g" \
        -e "s|{{NODEID}}|$i|g" \
        -e "s|{{CLAIM_NAME}}|${CLAIM_NAME}-${i}|g" \
        -e "s|{{S3_BUCKETNAME}}|$S3_BUCKETNAME|g" \
        -e "s|{{S3_ENDPOINT}}|$S3_ENDPOINT|g" \
        -e "s|{{S3_ACCESSKEY}}|$S3_ACCESSKEY|g" \
        -e "s|{{S3_SECRET}}|$S3_SECRET|g" \
        -e "s|{{S3_REGION}}|$S3_REGION|g" \
        "$TEMPLATE_FILE" > "$OUTPUT_FILE"
    echo "Generated: $OUTPUT_FILE"
done

echo "All job YAML files have been created."

