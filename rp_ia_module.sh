#!/usr/bin/env bash

IA_BASE_URL="${IA_BASE_URL:-https://management.azure.com}"
IA_API_VERSION="${IA_API_VERSION:-2025-04-01}"
IA_TIMEOUT_SECONDS="${IA_TIMEOUT_SECONDS:-60}"
IA_MAX_RETRIES="${IA_MAX_RETRIES:-6}"
IA_BACKOFF_SECONDS="${IA_BACKOFF_SECONDS:-1.5}"
IA_DEBUG="${IA_DEBUG:-false}"

ia_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

ia_log() {
  printf '%s %s\n' "$(ia_timestamp)" "$*"
}

ia_log_error() {
  printf '%s %s\n' "$(ia_timestamp)" "$*" >&2
}

ia_is_true() {
  local value="${1:-false}"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "TRUE" || "$value" == "yes" || "$value" == "YES" || "$value" == "on" || "$value" == "ON" ]]
}

ia_debug() {
  if ia_is_true "$IA_DEBUG"; then
    ia_log "[DEBUG] $*"
  fi
}

ia_get_access_token() {
  az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
}

ia_build_url() {
  local resource_path_or_url="$1"
  local api_version="${2:-$IA_API_VERSION}"

  if [[ "$resource_path_or_url" == http://* || "$resource_path_or_url" == https://* ]]; then
    if [[ "$resource_path_or_url" == *"api-version="* ]]; then
      printf '%s\n' "$resource_path_or_url"
    else
      local sep="?"
      [[ "$resource_path_or_url" == *"?"* ]] && sep="&"
      printf '%s%sapi-version=%s\n' "$resource_path_or_url" "$sep" "$api_version"
    fi
    return
  fi

  local resource_path="$resource_path_or_url"
  [[ "$resource_path" != /* ]] && resource_path="/$resource_path"

  local sep="?"
  [[ "$resource_path" == *"?"* ]] && sep="&"
  if [[ "$resource_path" != *"api-version="* ]]; then
    resource_path="${resource_path}${sep}api-version=${api_version}"
  fi

  printf '%s%s\n' "$IA_BASE_URL" "$resource_path"
}

ia_is_retryable_status() {
  local code="$1"
  [[ "$code" == "408" || "$code" == "409" || "$code" == "429" || "$code" == "500" || "$code" == "502" || "$code" == "503" || "$code" == "504" ]]
}

ia_request() {
  local method="$1"
  local resource_path_or_url="$2"
  local body_json="${3:-}"
  local api_version="${4:-$IA_API_VERSION}"

  local url
  url="$(ia_build_url "$resource_path_or_url" "$api_version")"
  ia_debug "Request prepared: method=${method^^} url=$url"

  local token
  token="$(ia_get_access_token)"
  ia_debug "Access token acquired from az account get-access-token"

  local attempt=0
  local max_retries="$IA_MAX_RETRIES"
  local backoff="$IA_BACKOFF_SECONDS"

  while true; do
    local headers_file body_file curl_err_file
    headers_file="$(mktemp)"
    body_file="$(mktemp)"
    curl_err_file="$(mktemp)"

    local http_status=""
    local curl_exit=0

    if [[ -n "$body_json" ]]; then
      ia_debug "Request body: $body_json"
      http_status=$(curl -sS -X "$method" "$url" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data "$body_json" \
        --connect-timeout "$IA_TIMEOUT_SECONDS" \
        --max-time "$IA_TIMEOUT_SECONDS" \
        -D "$headers_file" \
        -o "$body_file" \
        -w "%{http_code}" 2>"$curl_err_file") || curl_exit=$?
    else
      http_status=$(curl -sS -X "$method" "$url" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json" \
        --connect-timeout "$IA_TIMEOUT_SECONDS" \
        --max-time "$IA_TIMEOUT_SECONDS" \
        -D "$headers_file" \
        -o "$body_file" \
        -w "%{http_code}" 2>"$curl_err_file") || curl_exit=$?
    fi

    if [[ $curl_exit -eq 0 && "$http_status" -lt 400 ]]; then
      ia_debug "HTTP success: status=$http_status"
      if [[ -s "$body_file" ]]; then
        ia_debug "Response body: $(cat "$body_file")"
      else
        ia_debug "Response body: <empty>"
      fi
      cat "$body_file"
      rm -f "$headers_file" "$body_file" "$curl_err_file"
      return 0
    fi

    local retry_after=""
    retry_after=$(grep -i '^Retry-After:' "$headers_file" | head -n 1 | awk -F': ' '{print $2}' | tr -d '\r') || true

    if [[ $curl_exit -ne 0 ]]; then
      ia_debug "Transport failure from curl: exitCode=$curl_exit"
      if [[ -s "$curl_err_file" ]]; then
        ia_log_error "curl stderr: $(tr '\n' ' ' < "$curl_err_file")"
      fi
      if (( attempt < max_retries )); then
        attempt=$((attempt + 1))
        local delay
      delay=$(awk -v base="$backoff" -v i="$attempt" 'BEGIN { print base * (2 ^ (i - 1)) }')
        ia_log "Request failed at transport layer (attempt $attempt/$max_retries). Retrying in ${delay}s..."
        sleep "$delay"
        rm -f "$headers_file" "$body_file" "$curl_err_file"
        continue
      fi

      ia_log_error "${method^^} $url failed at transport layer after $attempt retries."
      rm -f "$headers_file" "$body_file" "$curl_err_file"
      return 1
    fi

    if ia_is_retryable_status "$http_status" && (( attempt < max_retries )); then
      ia_debug "Retryable HTTP status received: $http_status"
      attempt=$((attempt + 1))
      local delay
      if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        delay="$retry_after"
      else
        delay=$(awk -v base="$backoff" -v i="$attempt" 'BEGIN { print base * (2 ^ (i - 1)) }')
      fi
      ia_log "${method^^} $url returned HTTP $http_status (attempt $attempt/$max_retries). Retrying in ${delay}s..."
      sleep "$delay"
      rm -f "$headers_file" "$body_file" "$curl_err_file"
      continue
    fi

    ia_log_error "${method^^} $url failed with HTTP $http_status"
    ia_debug "Failed response headers: $(tr '\n' ' ' < "$headers_file")"
    if [[ -s "$curl_err_file" ]]; then
      ia_debug "curl stderr: $(tr '\n' ' ' < "$curl_err_file")"
    fi
    if [[ -s "$body_file" ]]; then
      cat "$body_file" >&2
    fi
    rm -f "$headers_file" "$body_file" "$curl_err_file"
    return 1
  done
}

ia_restore_point_collection_path() {
  local subscription_id="$1"
  local resource_group_name="$2"
  local restore_point_collection_name="$3"

  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/restorePointCollections/%s\n' \
    "$subscription_id" "$resource_group_name" "$restore_point_collection_name"
}

ia_restore_point_path() {
  local subscription_id="$1"
  local resource_group_name="$2"
  local restore_point_collection_name="$3"
  local restore_point_name="$4"

  printf '%s/restorePoints/%s\n' \
    "$(ia_restore_point_collection_path "$subscription_id" "$resource_group_name" "$restore_point_collection_name")" \
    "$restore_point_name"
}

ia_create_or_update_restore_point_collection() {
  local subscription_id="$1"
  local resource_group_name="$2"
  local restore_point_collection_name="$3"
  local location="$4"
  local source_vm_id="$5"
  local instant_access="${6:-true}"
  local tags_json="${7:-}"

  local body
  if [[ -n "$tags_json" ]]; then
    body=$(cat <<EOF
{
  "location": "$location",
  "properties": {
    "source": { "id": "$source_vm_id" },
    "instantAccess": $instant_access
  },
  "tags": $tags_json
}
EOF
)
  else
    body=$(cat <<EOF
{
  "location": "$location",
  "properties": {
    "source": { "id": "$source_vm_id" },
    "instantAccess": $instant_access
  }
}
EOF
)
  fi

  ia_request "PUT" \
    "$(ia_restore_point_collection_path "$subscription_id" "$resource_group_name" "$restore_point_collection_name")" \
    "$body"
}

ia_create_or_update_restore_point() {
  local subscription_id="$1"
  local resource_group_name="$2"
  local restore_point_collection_name="$3"
  local restore_point_name="$4"
  local consistency_mode="${5:-}"
  local instant_access_duration_minutes="${6:-}"
  local exclude_disks_json="${7:-}"  # JSON array: [{"id":"..."},...] or empty

  local props_parts=()
  [[ -n "$consistency_mode" ]] && props_parts+=('"consistencyMode": "'"$consistency_mode"'"')
  [[ -n "$instant_access_duration_minutes" ]] && props_parts+=('"instantAccessDurationMinutes": '"$instant_access_duration_minutes")
  [[ -n "$exclude_disks_json" ]] && props_parts+=('"excludeDisks": '"$exclude_disks_json")

  local props_inner=""
  local _idx
  for _idx in "${!props_parts[@]}"; do
    (( _idx > 0 )) && props_inner+=", "
    props_inner+="${props_parts[$_idx]}"
  done

  local body="{\"name\": \"$restore_point_name\", \"properties\": {$props_inner}}"
  ia_debug "Restore point request body: $body"

  ia_request "PUT" \
    "$(ia_restore_point_path "$subscription_id" "$resource_group_name" "$restore_point_collection_name" "$restore_point_name")" \
    "$body"
}

ia_get_restore_point() {
  local subscription_id="$1"
  local resource_group_name="$2"
  local restore_point_collection_name="$3"
  local restore_point_name="$4"

  ia_request "GET" \
    "$(ia_restore_point_path "$subscription_id" "$resource_group_name" "$restore_point_collection_name" "$restore_point_name")"
}

ia_get_restore_point_instance_view() {
  local subscription_id="$1"
  local resource_group_name="$2"
  local restore_point_collection_name="$3"
  local restore_point_name="$4"

  local path
  path="$(ia_restore_point_path "$subscription_id" "$resource_group_name" "$restore_point_collection_name" "$restore_point_name")"

  ia_request "GET" \
    "${path}?\$expand=instanceView"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cat <<'EOF'
This file is a reusable library. Source it from your script:
  source ./rp_ia_module.sh

Then call helper functions, for example:
  ia_create_or_update_restore_point_collection <subscriptionId> <resourceGroup> <rpcName> <location> <sourceVmId>
EOF
fi
