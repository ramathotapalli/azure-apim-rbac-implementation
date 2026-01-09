#!/bin/bash

# Function to recreate locks based on input
recreate_locks() {
  local resourceGroupName="$1"
  local locksInput="$2"

  # Check if locksInput is empty or "[]"
  if [[ -z "$locksInput" || "$locksInput" == "[]" ]]; then
    echo "No locks to recreate."
    return 0
  fi

  # Parse the JSON array and iterate through locks
  echo "$locksInput" | jq -c '.[]' | while read lock; do
    lockName=$(echo "$lock" | jq -r '.name')
    lockLevel=$(echo "$lock" | jq -r '.level')
    lockNotes=$(echo "$lock" | jq -r '.notes')

    if [[ -z "$lockName" || -z "$lockLevel" ]]; then
      echo "Warning: Missing name or level in lock data. Skipping lock."
      continue
    fi

    echo "Creating lock: $lockName (Level: $lockLevel, Notes: $lockNotes)"

    # Create the lock
    az lock create \
      --name "$lockName" \
      --resource-group "$resourceGroupName" \
      --lock-type "$lockLevel" \
      --notes "$lockNotes"

    if [ $? -eq 0 ]; then
      echo "Successfully created lock: $lockName"
    else
      echo "Failed to create lock: $lockName"
    fi
  done
}

# Main execution
if [[ $# -ge 2 ]]; then
  recreate_locks "$1" "$2"
else
  echo "Usage: $0 <resourceGroupName> '<locksJsonArray>'"
  exit 1
fi