#!/bin/bash

# Configuration
ES_HOST="http://localhost:9200"  # Change to your Elasticsearch host
REPOSITORY="tasklist-backup"       # Change to your snapshot repository
SNAPSHOT_PREFIX="backup_tasklist_1"

# Array of index sets
declare -a INDEX_SETS=(
    "tasklist-import-position-8.2.0_"
    "tasklist-process-instance-8.3.0_,tasklist-task-8.4.0_"
    "tasklist-task-8.4.0_*,-tasklist-task-8.4.0_"
    "tasklist-flownode-instance-8.3.0_,tasklist-variable-8.3.0_,tasklist-draft-task-variable-8.3.0_,tasklist-task-variable-8.3.0_"
    "tasklist-draft-task-variable-8.3.0_*,-tasklist-draft-task-variable-8.3.0_,tasklist-task-variable-8.3.0_*,-tasklist-task-variable-8.3.0_"
    "tasklist-form-8.4.0_,tasklist-metric-8.3.0_,tasklist-migration-steps-repository-1.1.0_,tasklist-process-8.4.0_,tasklist-web-session-1.1.0_,tasklist-user-1.4.0_"
)

# Function to create a snapshot
create_snapshot() {
    local snapshot_name="$1"
    local indices="$2"

    echo "Creating snapshot: $snapshot_name"
    RESPONSE=$(curl -s -X PUT "$ES_HOST/_snapshot/$REPOSITORY/$snapshot_name" -H "Content-Type: application/json" -d "{
      \"indices\": \"$indices\",
      \"ignore_unavailable\": true,
      \"include_global_state\": false
    }")

    if echo "$RESPONSE" | grep -q '"accepted":true'; then
        echo "Snapshot $snapshot_name started successfully."
    else
        echo "Failed to create snapshot: $snapshot_name"
        echo "Response: $RESPONSE"
        exit 1
    fi

    # Wait for snapshot completion
    while true; do
        STATUS=$(curl -s "$ES_HOST/_snapshot/$REPOSITORY/$snapshot_name")
        if echo "$STATUS" | grep -q '"state":"SUCCESS"'; then
            echo "Snapshot $snapshot_name completed successfully."
            break
        elif echo "$STATUS" | grep -q '"state":"FAILED"'; then
            echo "Snapshot $snapshot_name failed. Exiting."
            exit 1
        fi
        sleep 10
    done
}

# Iterate over index sets and back them up sequentially
for i in "${!INDEX_SETS[@]}"; do
    SNAPSHOT_NAME="${SNAPSHOT_PREFIX}_set_$((i+1))"
    create_snapshot "$SNAPSHOT_NAME" "${INDEX_SETS[$i]}"
done

echo "All snapshots completed successfully."
