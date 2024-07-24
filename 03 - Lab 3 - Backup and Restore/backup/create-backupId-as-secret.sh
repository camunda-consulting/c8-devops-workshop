
#!/bin/bash

# Generate the backupTimeId based on the current date and time
backupTimeId=$(date +"%Y%m%d%H%M%S")

# Check if the secret exists
kubectl get secret backup-timeid >/dev/null 2>&1

if [ $? -eq 0 ]; then
    # Secret exists, update it
    kubectl create secret generic backup-timeid --from-literal=backupTimeId=$backupTimeId --dry-run=client -o yaml | kubectl apply -f -
    echo "Updated secret with backupTimeId: $backupTimeId"
else
    # Secret does not exist, create it
    kubectl create secret generic backup-timeid --from-literal=backupTimeId=$backupTimeId
    echo "Created secret with backupTimeId: $backupTimeId"
fi
