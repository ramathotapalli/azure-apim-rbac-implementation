#!/bin/bash

# Function to identify locks and return their details as JSON
identify_locks() {
  local resourceGroupName="$1"

  local locks=$(az lock list --resource-group "$resourceGroupName" --output json 2>/dev/null)

  if [[ -n "$locks" ]] && [[ "$locks" != "[]" ]]; then
    # Construct the JSON array explicitly using jq
    formatted_locks=$(echo "$locks" | jq -c '.[] | {id: .id, level: .level, name: .name, notes: .notes}')

    # Construct the final JSON array with proper quotes
    final_output="["
    if [[ -n "$formatted_locks" ]]; then
      final_output+="$(echo "$formatted_locks" | tr '\n' ',' | sed 's/,$//')"
    fi
    final_output+="]"

    echo "$final_output"
    return 0
  else
    echo "[]" # Return an empty array if no locks are found.
    return 0
  fi
}

# Function to remove locks from a resource group
remove_locks() {
  local resourceGroupName="$1"
  local locks_json="$2"

  if [[ -z "$locks_json" ]]; then
    locks_json=$(identify_locks "$resourceGroupName")
  fi

  if [[ -n "$locks_json" ]]; then
    locks_array=$(echo "$locks_json" | jq -c '.[]') # Convert JSON array to newline-separated JSON objects
    if [[ -n "$locks_array" ]]; then
      echo "Removing locks from resource group: $resourceGroupName"
      while IFS= read -r lock_object; do
        lockName=$(echo "$lock_object" | jq -r '.name')

        echo "--- Deleting lock: $lockName"
        az lock delete --resource-group "$resourceGroupName" --name "$lockName"
      done <<< "$locks_array"
    else
      echo "No locks found in resource group."
    fi
  else
    echo "Failed to retrieve lock information."
  fi
}

# Main execution
main() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <operation> <resourceGroupName> [locks_json]"
    echo "  operations: identify, remove"
    exit 1
  fi

  operation="$1"
  resourceGroupName="$2"
  locks_json="$3"

  case "$operation" in
    identify)
      identify_locks "$resourceGroupName"
      ;;
    remove)
      remove_locks "$resourceGroupName" "$locks_json"
      ;;
    *)
      echo "Error: Unknown operation '$operation'. Valid operations are: identify, remove"
      exit 1
      ;;
  esac
}

# Call main with all arguments passed to the script
main "$@"