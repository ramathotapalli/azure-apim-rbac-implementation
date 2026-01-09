#!/bin/bash

# Script to delete specified RBAC roles and their assignments for a user or group in Azure

set -e
set -o pipefail

ROLE_DELETION_RETRIES=${ROLE_DELETION_RETRIES:-10}
ROLE_DELETION_WAIT=${ROLE_DELETION_WAIT:-60}

log() {
  local level=$1
  shift
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
}

handle_error() {
  local exit_code=$1
  local msg="$2"
  log "ERROR" "$msg"
  exit $exit_code
}

get_identity_info() {
  local identity="$1"
  local identityType="$2"
  local identity_info=""
  if [[ "$identityType" == "user" ]]; then
    identity_info=$(az ad user show --id "$identity" --output json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
      log "WARNING" "Failed as user. Trying as group..."
      identity_info=$(az ad group show --group "$identity" --output json 2>/dev/null)
      if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
        handle_error 1 "Failed to find identity as user or group: $identity"
      fi
      identityType="group"
    fi
  else
    identity_info=$(az ad group show --group "$identity" --output json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
      log "WARNING" "Failed as group. Trying as user..."
      identity_info=$(az ad user show --id "$identity" --output json 2>/dev/null)
      if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
        handle_error 1 "Failed to find identity as group or user: $identity"
      fi
      identityType="user"
    fi
  fi
  echo "$identity_info|$identityType"
}

delete_role_assignments() {
  local role_id="$1"
  local objectId="$2"
  local role_name="$3"
  local user_assignments assignment assignment_data principal_id scope
  user_assignments=$(az role assignment list --all --query "[?roleDefinitionId=='$role_id' && principalId=='$objectId']" --output json)
  local user_assignment_count
  user_assignment_count=$(echo "$user_assignments" | jq 'length')
  if [ "$user_assignment_count" -gt 0 ]; then
    for assignment in $(echo "$user_assignments" | jq -r '.[].id'); do
      log "INFO" "Removing role assignment: $assignment"
      if ! az role assignment delete --ids "$assignment"; then
        assignment_data=$(echo "$user_assignments" | jq -r --arg id "$assignment" '.[] | select(.id == $id)')
        principal_id=$(echo "$assignment_data" | jq -r '.principalId')
        scope=$(echo "$assignment_data" | jq -r '.scope')
        az role assignment delete --assignee "$principal_id" --role "$role_name" --scope "$scope" || \
        log "ERROR" "Failed to remove role assignment: $assignment"
        sleep 10
      fi
    done
  else
    log "INFO" "No assignments found for role \"$role_name\""
  fi
}

if [ "$#" -ne 2 ]; then
  handle_error 1 "Usage: $0 identityEmailOrName rolesToDeleteJson"
fi

identity=$1
rolesToDeleteJson=$2

log "INFO" "Parameters received:"
log "INFO" "Identity: $identity"
log "INFO" "Roles to Delete (JSON): $rolesToDeleteJson"

if [[ "$identity" == *@* ]]; then
  identityType="user"
  log "INFO" "Identity appears to be a user email: $identity"
else
  identityType="group"
  log "INFO" "Identity appears to be a group name: $identity"
fi

if ! echo "$rolesToDeleteJson" | jq -c . >/dev/null 2>&1; then
  handle_error 1 "Invalid JSON format for rolesToDelete."
fi

log "INFO" "Step 1: Retrieve Identity Info"
identity_info_and_type=$(get_identity_info "$identity" "$identityType")
identity_info=$(echo "$identity_info_and_type" | cut -d'|' -f1)
identityType=$(echo "$identity_info_and_type" | cut -d'|' -f2)

log "INFO" "Identity confirmed as $identityType"
objectId=$(echo "$identity_info" | jq -r '.id')
if [ -z "$objectId" ] || [ "$objectId" == "null" ]; then
  handle_error 1 "Failed to retrieve Object ID for $identityType $identity"
fi
log "INFO" "Object ID: $objectId"

current_subscription=$(az account show --query id -o tsv)
log "INFO" "Current subscription ID: ${current_subscription:-Unavailable}"

log "INFO" "Step 3: List all current role assignments"
all_roles=$(az role assignment list --assignee "$objectId" --all --include-inherited --include-groups --output json)
log "INFO" "All current role assignments:"
if [ "$(echo "$all_roles" | jq 'length')" -eq 0 ]; then
  log "INFO" "No current role assignments found for $identityType $identity."
else
  echo "$all_roles" | jq -r '.[] | "  Role: \(.roleDefinitionName), Scope: \(.scope)"'
fi

roles_count=$(echo "$rolesToDeleteJson" | jq 'length')
if [ "$roles_count" -eq 0 ]; then
  log "INFO" "No roles provided to delete. Exiting."
  exit 0
fi

log "INFO" "Number of roles to process: $roles_count"

for i in $(seq 0 $(($roles_count - 1))); do
  role_name=$(echo "$rolesToDeleteJson" | jq -r ".[$i]")
  log "INFO" "Processing role: \"$role_name\""

  role_exists_output=$(az role definition list --name "$role_name" --output json)
  if [ "$(echo "$role_exists_output" | jq '. | length')" -eq 0 ]; then
    log "INFO" "Role \"$role_name\" does not exist. Skipping."
    continue
  fi

  role_id=$(echo "$role_exists_output" | jq -r '.[0].id')
  is_custom=$(echo "$role_exists_output" | jq -r '.[0].roleType')

  delete_role_assignments "$role_id" "$objectId" "$role_name"

  if [[ "${is_custom,,}" == "customrole" ]]; then
    log "INFO" "Custom role. Verifying no other users have this role..."
    others=$(az role assignment list --all \
      --query "[?roleDefinitionId=='$role_id' && principalId!='$objectId']" -o json)

    if [ "$(echo "$others" | jq length)" -gt 0 ]; then
      log "INFO" "Role is still assigned to other identities. Skipping delete."
      continue
    fi

    log "INFO" "Waiting $ROLE_DELETION_WAIT seconds for RBAC propagation..."
    sleep $ROLE_DELETION_WAIT

    retry_count=0
    deletion_success=false
    last_error=""

    set +e  # Disable immediate exit on error for the retry loop

    while [ $retry_count -lt $ROLE_DELETION_RETRIES ] && [ "$deletion_success" = false ]; do
      log "INFO" "Attempt $((retry_count + 1)) to delete role \"$role_name\""

      log "DEBUG" "About to run: az role definition delete --name \"$role_name\" --subscription \"$current_subscription\""
      delete_output=$(az role definition delete --name "$role_name" --subscription "$current_subscription" 2>&1)
      exit_code=$?
      log "DEBUG" "Command exit code: $exit_code"
      log "DEBUG" "Command output: $delete_output"

      if [ $exit_code -eq 0 ]; then
        log "INFO" "Successfully deleted role: $role_name"
        deletion_success=true
        break
      else
        if echo "$delete_output" | grep -qi "AuthorizationFailed"; then
          handle_error 1 "Authorization failed for role deletion: $delete_output"
        elif echo "$delete_output" | grep -qi "not found\|does not exist\|could not be found"; then
          log "INFO" "Role already deleted. Treating as success."
          deletion_success=true
          break
        elif echo "$delete_output" | grep -qi "RoleDefinitionHasAssignments"; then
          log "WARNING" "Azure still sees lingering assignments. Waiting $ROLE_DELETION_WAIT s..."
        else
          log "WARNING" "Unexpected error. Waiting $ROLE_DELETION_WAIT s..."
        fi
        sleep $ROLE_DELETION_WAIT
      fi

      retry_count=$((retry_count + 1))
    done

    set -e  # Re-enable immediate exit on error

    if [ "$deletion_success" = false ]; then
      handle_error 1 "Failed to delete role definition after $ROLE_DELETION_RETRIES attempts."
    fi
  else
    log "INFO" "Skipping built-in role \"$role_name\""
  fi
done

log "INFO" "Step 5: Final check for remaining assignments"
remaining_roles=$(az role assignment list --assignee "$objectId" --all --include-inherited --include-groups --output json)
remaining_count=$(echo "$remaining_roles" | jq 'length')

log "INFO" "$identityType has $remaining_count remaining assignments:"
if [ "$remaining_count" -gt 0 ]; then
  echo "$remaining_roles" | jq -r '.[] | "  Role: \(.roleDefinitionName), Scope: \(.scope)"'
else
  log "INFO" "No remaining assignments."
fi

log "INFO" "Role management process complete."
exit 0
