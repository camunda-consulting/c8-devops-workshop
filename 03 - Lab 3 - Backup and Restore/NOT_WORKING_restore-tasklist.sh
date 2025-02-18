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

# Function to restore a snapshot
restore_snapshot() {
    local snapshot_name="$1"
    local indices="$2"

    echo "Restoring snapshot: $snapshot_name"
    RESPONSE=$(curl -s -X POST "$ES_HOST/_snapshot/$REPOSITORY/$snapshot_name/_restore" -H "Content-Type: application/json" -d "{
      \"indices\": \"$indices\",
      \"ignore_unavailable\": true,
      \"include_global_state\": false
    }")

    if echo "$RESPONSE" | grep -q '"accepted":true'; then
        echo "Restore of $snapshot_name started successfully."
    else
        echo "Failed to restore snapshot: $snapshot_name"
        echo "Response: $RESPONSE"
        exit 1
    fi

    # Wait for restore completion
    while true; do
        STATUS=$(curl -s "$ES_HOST/_recovery")
        if echo "$STATUS" | grep -q '"stage":"DONE"'; then
            echo "Restore $snapshot_name completed successfully."
            break
        elif echo "$STATUS" | grep -q '"stage":"FAILED"'; then
            echo "Restore $snapshot_name failed. Exiting."
            exit 1
        fi
        sleep 10
    done
}

# Iterate over index sets and restore them sequentially
for i in "${!INDEX_SETS[@]}"; do
    SNAPSHOT_NAME="${SNAPSHOT_PREFIX}_set_$((i+1))"
    restore_snapshot "$SNAPSHOT_NAME" "${INDEX_SETS[$i]}"
done

echo "All restores completed successfully."
