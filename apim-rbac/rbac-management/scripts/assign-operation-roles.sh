#!/bin/bash

# assign-operation-roles.sh
# Script to set up operation-specific RBAC roles in Azure API Management.
# This script creates and assigns custom roles that allow operation management
# but prevent API deletion. Automatically detects if the identity is a user or group.

set -e
set -o pipefail

# Configurable wait/retry parameters
ROLE_PROPAGATION_WAIT=${ROLE_PROPAGATION_WAIT:-90}
ROLE_ASSIGNMENT_RETRIES=${ROLE_ASSIGNMENT_RETRIES:-5}
ROLE_ASSIGNMENT_RETRY_WAIT=${ROLE_ASSIGNMENT_RETRY_WAIT:-20}
ROLE_VERIFY_RETRIES=${ROLE_VERIFY_RETRIES:-8}
ROLE_VERIFY_WAIT=${ROLE_VERIFY_WAIT:-15}

log() {
  local level=$1
  shift
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
}

role_exists() {
  local roleName="$1"
  local scope="$2"
  local output
  if [ -n "$scope" ]; then
    output=$(az role definition list --name "$roleName" --scope "$scope" --output json 2>&1)
  else
    output=$(az role definition list --name "$roleName" --output json 2>&1)
  fi
  if [ $? -ne 0 ]; then
    log "ERROR" "Failed to list role definitions. Azure CLI Error: $output"
    return 2
  fi
  [ "$(echo "$output" | jq '. | length')" -gt 0 ]
}

delete_role_assignments() {
  local role_id="$1"
  local objectId="$2"
  local roleName="$3"
  local all_assignments_output all_assignments assignment_count
  all_assignments_output=$(az role assignment list --all --query "[?roleDefinitionId=='$role_id' && principalId=='$objectId']" --output json 2>&1)
  if [ $? -ne 0 ]; then
    log "WARNING" "Failed to list role assignments: $all_assignments_output"
    all_assignments="[]"
  else
    all_assignments="$all_assignments_output"
  fi
  assignment_count=$(echo "$all_assignments" | jq 'length')
  log "INFO" "Found $assignment_count assignments to delete."
  if [ "$assignment_count" -gt 0 ]; then
    for assignment in $(echo "$all_assignments" | jq -r '.[].id'); do
      log "INFO" "Deleting role assignment: $assignment"
      delete_output=$(az role assignment delete --ids "$assignment" 2>&1)
      if [ $? -ne 0 ]; then
        log "WARNING" "Error: Failed to delete existing role assignment $assignment. Error details: $delete_output"
        assignment_data=$(echo "$all_assignments" | jq -r --arg id "$assignment" '.[]. | select(.id == $id)')
        principal_id=$(echo "$assignment_data" | jq -r '.principalId')
        scope=$(echo "$assignment_data" | jq -r '.scope')
        log "INFO" "Deleting by principal ID ($principal_id), role name ($roleName), and scope ($scope)"
        alt_delete_output=$(az role assignment delete --assignee "$principal_id" --role "$roleName" --scope "$scope" 2>&1)
        if [ $? -ne 0 ]; then
          log "WARNING" "Warning: Could not delete assignment $assignment. Error: $alt_delete_output. Continuing..."
        else
          log "INFO" "Successfully deleted assignment using alternative method."
        fi
      else
        log "INFO" "Successfully deleted existing role assignment $assignment."
      fi
      sleep 2
    done
  else
    log "INFO" "No existing role assignments found for this role."
  fi
}

assign_role_with_retries() {
  local objectId="$1"
  local roleName="$2"
  local operationScope="$3"
  local retries=${ROLE_ASSIGNMENT_RETRIES}
  local retry_wait=${ROLE_ASSIGNMENT_RETRY_WAIT}
  local retry_count=0
  local assignment_success=false
  while [ $retry_count -lt $retries ] && [ "$assignment_success" = false ]; do
    log "INFO" "Attempt $((retry_count + 1)) of $retries"
    assignment_exists_output=$(az role assignment list --assignee "$objectId" --role "$roleName" --scope "$operationScope" --output json 2>&1)
    assignment_exists_result=$?
    if [ $assignment_exists_result -eq 0 ] && [ "$(echo "$assignment_exists_output" | jq 'length')" -gt 0 ]; then
      log "INFO" "Role assignment already exists for $objectId at scope: $operationScope. Skipping creation."
      assignment_success=true
    else
      if [ $assignment_exists_result -ne 0 ]; then
        log "WARNING" "Error checking if assignment exists: $assignment_exists_output"
      fi
      assignment_output=$(az role assignment create --assignee "$objectId" --role "$roleName" --scope "$operationScope" 2>&1)
      assignment_result=$?
      if [ $assignment_result -eq 0 ]; then
        log "INFO" "Successfully assigned custom role '$roleName' for operation scope: $operationScope"
        assignment_success=true
      else
        log "WARNING" "Failed to assign custom role '$roleName' for operation scope: $operationScope. Azure CLI Error: $assignment_output"
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $retries ]; then
          wait_time=$((retry_wait * retry_count))
          log "INFO" "Assignment failed. Waiting $wait_time seconds before retry..."
          sleep $wait_time
        else
          log "ERROR" "Failed to assign custom role '$roleName' after $retries attempts for operation scope: $operationScope."
        fi
      fi
    fi
    if [ "$assignment_success" = false ]; then
      sleep 5
    fi
  done
  $assignment_success && return 0 || return 1
}

verify_role_assignment() {
  local objectId="$1"
  local roleName="$2"
  local operationScope="$3"
  local retries=${ROLE_VERIFY_RETRIES}
  local wait_time=${ROLE_VERIFY_WAIT}
  local verify_count=0
  local role_assignment_output=""
  local role_assignment_result=1
  while [ $verify_count -lt $retries ]; do
    log "INFO" "Checking role assignments at scope $operationScope (attempt $((verify_count+1))/$retries)..."
    role_assignment_output=$(az role assignment list --assignee "$objectId" --role "$roleName" --scope "$operationScope" --output json 2>&1)
    role_assignment_result=$?
    log "DEBUG" "az role assignment list output: $role_assignment_output"
    if [ $role_assignment_result -eq 0 ] && [ -n "$role_assignment_output" ] && [ "$role_assignment_output" != "[]" ]; then
      log "INFO" "Success: Custom role assigned at $operationScope"
      return 0
    else
      log "WARNING" "Role assignment not yet visible at $operationScope. Waiting $((wait_time * (verify_count + 1))) seconds before retry..."
      sleep $((wait_time * (verify_count + 1)))
    fi
    verify_count=$((verify_count + 1))
  done
  log "ERROR" "Role assignment failed at scope $operationScope after multiple verification attempts."
  return 1
}

if [ "$#" -ne 6 ]; then
  log "ERROR" "Usage: $0 subscriptionId resourceGroup apimInstance identityEmailOrName apiName operationsJson"
  exit 1
fi

subscriptionId=$1
resourceGroup=$2
apimInstance=$3
identity=$4
apiName=$5
operationsJson=$6

log "INFO" "Parameters received:"
log "INFO" "Subscription ID: $subscriptionId"
log "INFO" "Resource Group: $resourceGroup"
log "INFO" "APIM Instance: $apimInstance"
log "INFO" "Identity: $identity"
log "INFO" "API Name: $apiName"
log "INFO" "Operation Names JSON: $operationsJson"

if [[ "$identity" == *@* ]]; then
  identityType="user"
  log "INFO" "Identity appears to be a user email: $identity"
else
  identityType="group"
  log "INFO" "Identity appears to be a group name: $identity"
fi

if ! echo "$operationsJson" | jq . >/dev/null 2>&1; then
  log "ERROR" "Invalid JSON format for operations."
  exit 1
fi

if [ -z "$operationsJson" ] || [ "$operationsJson" == "[]" ] || [ "$operationsJson" == "null" ]; then
  log "ERROR" "No operation names provided. Skipping custom role creation."
  exit 1
fi

log "INFO" "Step 1: Retrieve Identity Info"
identity_info=""
if [[ "$identityType" == "user" ]]; then
  log "INFO" "Looking up user information by email..."
  identity_info=$(az ad user show --id "$identity" --output json 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
    log "WARNING" "Failed to retrieve user by email. Will try to look up as group..."
    identity_info=$(az ad group show --group "$identity" --output json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
      log "ERROR" "Failed to find identity as either user or group: $identity"
      exit 1
    else
      log "INFO" "Successfully found as group despite having email format."
      identityType="group"
    fi
  fi
else
  log "INFO" "Looking up group information by name..."
  identity_info=$(az ad group show --group "$identity" --output json 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
    log "WARNING" "Failed to retrieve group by name. Will try to look up as user..."
    identity_info=$(az ad user show --id "$identity" --output json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$identity_info" ] || ! echo "$identity_info" | jq . >/dev/null 2>&1; then
      log "ERROR" "Failed to find identity as either group or user: $identity"
      exit 1
    else
      log "INFO" "Successfully found as user despite not having email format."
      identityType="user"
    fi
  fi
fi

log "INFO" "Identity confirmed as $identityType"

log "INFO" "Step 2: Extract Object ID"
objectId=$(echo "$identity_info" | jq -r '.id')
if [ -z "$objectId" ] || [ "$objectId" == "null" ]; then
  log "ERROR" "Failed to retrieve Object ID for $identityType $identity"
  exit 1
fi
log "INFO" "Object ID: $objectId"

log "INFO" "Step 3: Extract Identity Name for Role Naming"
if [[ "$identityType" == "user" ]]; then
  if [[ "$identity" == *@* ]]; then
    identityName=$(echo "$identity" | cut -d'@' -f1)
  else
    identityName=$(echo "$identity_info" | jq -r '.userPrincipalName' | cut -d'@' -f1)
    if [ -z "$identityName" ] || [ "$identityName" == "null" ]; then
      identityName=$(echo "$identity_info" | jq -r '.displayName' | tr ' ' '-')
    fi
  fi
else
  identityName=$(echo "$identity_info" | jq -r '.displayName' | tr ' ' '-')
  if [ -z "$identityName" ] || [ "$identityName" == "null" ]; then
    identityName=$(echo "$identity" | tr ' ' '-')
  fi
fi

log "INFO" "Identity Name for Role: $identityName"

log "INFO" "Step 4: Define Resource IDs"
apimServiceId="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimInstance"
apiId="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimInstance/apis/$apiName"
log "INFO" "APIM Service ID: $apimServiceId"
log "INFO" "API ID: $apiId"
assignableScopes=()

log "INFO" "Step 5: Process Operations"
for operationName in $(echo "$operationsJson" | jq -r '.[]'); do
  log "INFO" "Processing API Operation: $operationName"
  apiOperationId="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimInstance/apis/$apiName/operations/$operationName"
  log "INFO" "Checking if operation resource exists: $apiOperationId"
  if ! az resource show --ids "$apiOperationId" --output none 2>/dev/null; then
    log "ERROR" "Operation resource does not exist: $apiOperationId. Skipping this operation."
    continue
  fi
  assignableScopes+=("$apiOperationId")
done

if [ ${#assignableScopes[@]} -eq 0 ]; then
  log "ERROR" "No valid operation names found in the provided JSON or none exist in Azure."
  exit 1
fi

roleName="OperationRole-${identityType}-${identityName}-${apiName}"
log "INFO" "Role Name: $roleName"

log "INFO" "Step 6: Check if Role Exists"
if role_exists "$roleName"; then
  log "INFO" "Role '$roleName' already exists. Modifying the role."
  role_action="updated"
  log "INFO" "Step 6.1: Check for Existing Role Assignments"
  other_roles=$(az role assignment list --assignee "$objectId" --include-inherited --include-groups --output json | jq '[.[] | {name: .roleDefinitionName, scope: .scope}]')
  log "INFO" "The $identityType currently has the following role assignments:"
  if [ "$(echo "$other_roles" | jq 'length')" -eq 0 ]; then
    log "INFO" "No current role assignments found for $identityType $identity."
  else
    echo "$other_roles" | jq -r '.[] | "  Role: \(.name), Scope: \(.scope)"'
  fi
  log "INFO" "Step 6.2: Looking for any higher-level roles that might override our restrictions"
  conflicting_roles=$(echo "$other_roles" | jq -r '.[] | select(.name | contains("Owner") or contains("Contributor") or contains("Administrator"))')
  if [ -n "$conflicting_roles" ]; then
    log "WARNING" "The $identityType has higher-level roles that might override custom role restrictions:"
    echo "$conflicting_roles" | jq -r '.name + " at scope: " + .scope'
    log "WARNING" "These roles might need to be removed or the $identityType should be switched to a more restricted role."
  fi
  log "INFO" "Step 7: Delete Existing Role Assignments for the $identityType and Role"
  role_id=$(az role definition list --name "$roleName" --output json | jq -r '.[0].id')
  delete_role_assignments "$role_id" "$objectId" "$roleName"
else
  log "INFO" "Role '$roleName' does not exist. Creating a new role."
  role_action="created"
fi

log "INFO" "Step 8: Create/Modify Role Definition JSON"
roleDefinition=$(jq -n --arg name "$roleName" \
  --arg desc "Custom role for managing specific operations within the $apiName API in APIM" \
  --argjson scopes "$(printf '%s\n' "${assignableScopes[@]}" | jq -R . | jq -s .)" '{
  "name": $name,
  "description": $desc,
  "actions": [
    "Microsoft.ApiManagement/service/apis/read",
    "Microsoft.ApiManagement/service/apis/operations/read",
    "Microsoft.ApiManagement/service/apis/operations/write",
    "Microsoft.ApiManagement/service/apis/operations/policies/read",
    "Microsoft.ApiManagement/service/apis/operations/policies/write"
  ],
  "notActions": [
    "Microsoft.ApiManagement/service/apis/write",
    "Microsoft.ApiManagement/service/apis/delete",
    "Microsoft.ApiManagement/service/apis/policies/write",
    "Microsoft.ApiManagement/service/apis/policies/delete",
    "Microsoft.ApiManagement/service/apis/revisions/*",
    "Microsoft.ApiManagement/service/apis/schemas/*",
    "Microsoft.ApiManagement/service/users/*",
    "Microsoft.ApiManagement/service/gateways/*"
  ],
  "dataActions": [],
  "notDataActions": [],
  "assignableScopes": $scopes
}')

log "INFO" "Role Definition JSON:"
echo "$roleDefinition" | jq .

log "INFO" "Step 9: Create/Update the Role Definition"
if [ "$role_action" == "updated" ]; then
  log "INFO" "Updating existing role definition '$roleName'..."
  echo "$roleDefinition" | az role definition update --role-definition @-
else
  log "INFO" "Creating new role definition '$roleName'..."
  echo "$roleDefinition" | az role definition create --role-definition @-
fi

if [ $? -ne 0 ]; then
  log "ERROR" "Failed to create/update role definition '$roleName'."
  log "ERROR" "This might be due to permissions issues or malformed JSON."
  log "ERROR" "Please check if you have the 'Microsoft.Authorization/roleDefinitions/write' permission."
  exit 1
fi

log "INFO" "Role '$roleName' has been $role_action."
log "INFO" "Waiting for role definition to propagate..."
sleep $ROLE_PROPAGATION_WAIT

log "INFO" "Step 10: Assign API Management Service Reader Role"
assignment_output=$(az role assignment create --assignee "$objectId" --role "API Management Service Reader Role" --scope "$apimServiceId" 2>&1)
if [ $? -ne 0 ]; then
  log "ERROR" "Failed to assign API Management Service Reader Role."
  log "ERROR" "Azure CLI Error: $assignment_output"
  exit 1
else
  log "INFO" "Successfully assigned API Management Service Reader Role."
fi

log "INFO" "Step 11: Verify Role Exists in All Target Scopes Before Assignment"
for operationScope in "${assignableScopes[@]}"; do
  max_verify_attempts=$ROLE_VERIFY_RETRIES
  attempt=0
  role_verified=false
  while [ $attempt -lt $max_verify_attempts ] && [ "$role_verified" = false ]; do
    log "INFO" "Verifying role exists at scope ($attempt/$max_verify_attempts): $operationScope"
    if role_exists "$roleName" "$operationScope"; then
      log "INFO" "Role verified at scope: $operationScope"
      role_verified=true
    else
      attempt=$((attempt + 1))
      log "INFO" "Role not yet available at scope. Waiting $ROLE_VERIFY_WAIT seconds..."
      sleep $ROLE_VERIFY_WAIT
    fi
  done
  if [ "$role_verified" = false ]; then
    log "WARNING" "Could not verify role at scope after multiple attempts: $operationScope"
    log "WARNING" "Will still attempt assignment but it may fail."
  fi
done

log "INFO" "Step 12: Assign the Custom Role to the $identityType for each Operation"
failed_assignments=0
for operationScope in "${assignableScopes[@]}"; do
  log "INFO" "Assigning custom role '$roleName' for operation scope: $operationScope"
  if ! assign_role_with_retries "$objectId" "$roleName" "$operationScope"; then
    failed_assignments=$((failed_assignments + 1))
  fi
  log "INFO" "---"
done

log "INFO" "Step 13: Check Role Assignments"
role_assignment=$(az role assignment list --assignee "$objectId" --output json 2>/dev/null)
if [ $? -ne 0 ]; then
  log "ERROR" "Failed to list role assignments."
  exit 1
fi

if [ -z "$role_assignment" ]; then
  log "ERROR" "Role assignment check failed for $identityType '$identity'. No role assignments found."
  exit 1
else
  log "INFO" "Success: Roles assigned successfully to $identityType '$identity'"
  if [ $failed_assignments -gt 0 ]; then
    log "WARNING" "$failed_assignments assignment(s) failed. Some permissions may not be properly set."
  fi
fi

log "INFO" "Step 14: Verify Final Permissions and Explicitly Test for Operation Deletion Access"
higher_role_access=$(az role assignment list --assignee "$objectId" --include-inherited --include-groups --output json |
  jq -r '.[] | select(.roleDefinitionName | contains("Owner") or contains("Contributor") or contains("Administrator")) |
  select(.scope | contains("/providers/Microsoft.ApiManagement/") | not)')

if [ -n "$higher_role_access" ]; then
  log "WARNING" "$identityType still has higher-level roles that might allow API deletion:"
  echo "$higher_role_access" | jq -r '.roleDefinitionName + " at scope: " + .scope'
  log "WARNING" "Recommendation: Remove these higher-level role assignments to ensure API protection."
else
  log "INFO" "No conflicting higher-level roles detected. API deletion should be properly restricted."
fi

if [ $failed_assignments -gt 0 ]; then
  log "WARNING" "Operation-specific RBAC role assignment completed with $failed_assignments failures for API '$apiName' and $identityType '$identity'."
  exit 1
else
  log "INFO" "Operation-specific RBAC role assignment completed successfully for API '$apiName' and $identityType '$identity'."
  exit 0
fi