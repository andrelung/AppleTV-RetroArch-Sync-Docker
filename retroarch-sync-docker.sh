#!/usr/bin/bash
###############################################################################
# retroarch-sync.sh (with Debug Output)
#
# A script that:
#   1) Waits for RetroArch's GCDWebUploader to be up.
#   2) Backs up certain paths (one-way).
#   3) Then loops two-way sync, using Last-Modified timestamps
#      from HEAD requests for each file.
#   4) Includes debug statements for easier troubleshooting.
###############################################################################

# We do NOT use `set -e` so partial errors don't kill the script immediately.
# We'll rely on skipping logic for errors.
# set -u #this is problematic with setting variables in docker

###############################################################################
# USER CONFIGURATION
###############################################################################
#ATVHOST="192.168.1.41" #set by docker-env
#ATVPORT="80"           #set by docker-env

#LOCAL_BASE_DIR="./LivingRoom"     # local parent directory set by docker
#REMOTE_BASE_PATH="/RetroArch"     # not used in script, but you can reference

# Folders with two-way sync
TWOWAY_SYNC_PATHS=(
  "/downloads"
  "/saves"
)

# Folders to "backup only" (AppleTV -> local)
BACKUP_ONLY_PATHS=(
  "/config"
)

# Folders to EXCLUDE (ignored entirely)
EXCLUDE_PATHS=(
  "/downloads/cloud_backups"
)

MAX_RETRIES=3
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=120

# How frequently do we re-check two-way sync in the infinite loop
SYNC_LOOP_INTERVAL=600  # seconds 60*10 = 10 minutes

###############################################################################
# INTERNAL GLOBALS
###############################################################################
BASE_URL="http://${ATVHOST}:${ATVPORT}"
LIST_ENDPOINT="${BASE_URL}/list"
DOWNLOAD_ENDPOINT="${BASE_URL}/download"
UPLOAD_ENDPOINT="${BASE_URL}/upload"
MOVE_ENDPOINT="${BASE_URL}/move"

LOCAL_BASE_DIR="${LOCAL_BASE_DIR%/}"  # remove trailing slash if any

###############################################################################
# FUNCTION: wait_for_port_open
###############################################################################
function wait_for_port_open() {
  echo ">> Checking if RetroArch's HTTP server is open on ${ATVHOST}:${ATVPORT}..."
  until nc -z -w3 "${ATVHOST}" "${ATVPORT}"; do
    sleep 5
  done
  echo ">> Port ${ATVPORT} is open on ${ATVHOST}!"
}

###############################################################################
# FUNCTION: urlencode_path
#   Replaces / -> %2F, space -> %20, etc.
###############################################################################

# The old sed-approach did not encode [, ], (, ), !, etc., as well as slashes (to %2F), spaces, etc.
function urlencode_path() {
  jq -rn --arg s "$1" '$s|@uri'
}

###############################################################################
# EXCLUSION/CLASSIFICATION CHECKS
###############################################################################
function is_excluded_path() {
  local p="$1"
  if [[ "$p" == *.old ]]; then
    return 0  # skip old files
  fi

  if [[ "$p" =~ (^|/)\@eaDir(/|$) ]]; then
    return 0 # skip synology metadata folders
  fi

  for ep in "${EXCLUDE_PATHS[@]}"; do
    if [[ "$p" == "$ep"* ]]; then
      return 0  # skip these
    fi
  done
  return 1
}

function is_backup_only_path() {
  local p="$1"
  for bp in "${BACKUP_ONLY_PATHS[@]}"; do
    if [[ "$p" == "$bp"* ]]; then
      return 0
    fi
  done
  return 1
}

function is_twoway_sync_path() {
  local p="$1"
  for tw in "${TWOWAY_SYNC_PATHS[@]}"; do
    if [[ "$p" == "$tw"* ]]; then
      return 0
    fi
  done
  return 1
}

###############################################################################
# FUNCTION: list_remote_dir
#   Returns JSON for the items in remote_dir, skipping .old.
###############################################################################
function list_remote_dir() {
  local remote_dir="$1"
  # Remove trailing slashes
  remote_dir="$(echo "$remote_dir" | sed 's:/*$::')"

  if is_excluded_path "$remote_dir"; then
    echo "[]"
    return 0
  fi

  local escaped_dir
  escaped_dir="$(urlencode_path "$remote_dir")"
  local url="${LIST_ENDPOINT}?path=${escaped_dir}"


  local tries=0
  while (( tries < MAX_RETRIES )); do
    local result
    result="$(curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" \
                    --max-time "$CURL_MAX_TIME" \
                    "$url")"
    local ec=$?

    # keep the debug information, but send it to stderr
    #echo "[Debug] curl-result for remote '$remote_dir': $result" >&2

    if [[ $ec -eq 0 ]]; then

      # always deliver a JSON array – fall back to [] on any problem
      local filtered
      filtered="$(echo "$result" |
                  jq -c 'if type=="array"
                           then [ .[] | select(.name|endswith(".old")|not) ]
                           else []
                         end' 2>/dev/null)" || true
      [[ -z $filtered ]] && filtered='[]'
      echo "$filtered"
      return 0

    else
      (( tries++ ))
      sleep 2
      wait_for_port_open
    fi
  done

  # If we exhausted all retries
  echo "[]"
  return 0
}

###############################################################################
# FUNCTION: get_remote_mtime
#   HEAD request to get Last-Modified. Convert to epoch. Return 0 if missing.
###############################################################################
function get_remote_mtime() {
  local remote_path="$1"

  # URL-encode the path and prepare the request
  local escaped
  escaped="$(urlencode_path "$remote_path")"
  local url="${DOWNLOAD_ENDPOINT}?path=${escaped}"

  # Capture the HEAD response
  local head_out
  head_out="$(curl -sSI --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$url" 2>/dev/null)"
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    echo 0  # Fail gracefully
    return 0
  fi

  # Extract 'Last-Modified' and convert to epoch
  local lastmod
  lastmod="$(echo "$head_out" | awk -F': ' '/^Last-Modified:/ {print $2}' | tr -d '\r')"
  if [[ -z "$lastmod" ]]; then
    echo 0  # Fail gracefully
    return 0
  fi

  # Convert the Last-Modified timestamp to epoch
  local epoch
  epoch="$(date -d "$lastmod" +%s 2>/dev/null || echo 0)"
  echo "$epoch"
}

###############################################################################
# FUNCTION: stat_local_mtime
#   Return local file's epoch mtime or 0 if missing
###############################################################################
function stat_local_mtime() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo 0
    return
  fi
  local ts
  ts="$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
  echo "$ts"
}

###############################################################################
# remote_file_exists -> 0 if yes, 1 if no
###############################################################################
function remote_file_exists() {
  local path="$1"
  local dir
  dir="$(dirname "$path")"
  local base
  base="$(basename "$path")"

  local listing
  listing="$(list_remote_dir "$dir")"
  # see if any .name == base
  echo "$listing" | jq -e --arg b "$base" 'map(select(.name == $b)) | length > 0' >/dev/null
}

###############################################################################
# FUNCTION: move_remote_file (rename old -> .old, then rename .part -> final)
###############################################################################
function move_remote_file_safely() {
  local part_path="$1"      # e.g. /RetroArch/saves/myfile.srm.part
  local final_path="$2"     # e.g. /RetroArch/saves/myfile.srm

  # 1) If final_path exists, rename it to .old
  #    We'll do a small trick: see if final_path is in the listing
  #    If it is, rename it to final_path.old
  if remote_file_exists "$final_path"; then
    local final_path_old="${final_path}.old"
    echo "   (Renaming existing $final_path => $final_path_old)"
    do_remote_rename "$final_path" "$final_path_old"
  fi

  # 2) rename .part -> final
  echo "   (Renaming $part_path => $final_path)"
  do_remote_rename "$part_path" "$final_path"
}

###############################################################################
# FUNCTION: do_remote_rename
###############################################################################
function do_remote_rename() {
  local oldp="$1"
  local newp="$2"

  local old_esc
  old_esc="$(urlencode_path "$oldp")"
  # echo "old_esc ${old_esc}"
  local new_esc
  new_esc="$(urlencode_path "$newp")"
  # echo "new_esc ${new_esc}"
  # echo -d \"oldPath=${old_esc}&newPath=${new_esc}\"

  local tries=0
  while (( tries < MAX_RETRIES )); do
    if curl -sS --fail \
         --connect-timeout "$CURL_CONNECT_TIMEOUT" \
         --max-time "$CURL_MAX_TIME" \
         -X POST \
         -d "oldPath=${old_esc}&newPath=${new_esc}" \
         "${MOVE_ENDPOINT}" \
       >/dev/null; then
      return 0
    fi

    (( tries++ ))
    echo "   do_remote_rename() failed. Retrying..."
    sleep 3
    wait_for_port_open
  done

  echo "ERROR: Could not rename $oldp -> $newp"
  return 1
}

###############################################################################
# FUNCTION: two_way_sync_dir
#   Recur into directories, HEAD files for last-mod, compare with local mtime.
###############################################################################
function two_way_sync_dir() {
  local remote_dir="$1"
  local local_dir="$2"

  # Remove trailing slash
  remote_dir="$(echo "$remote_dir" | sed 's:/*$::')"


  # Skip if excluded
  if is_excluded_path "$remote_dir"; then
    return
  fi

  # Check if it's truly in two-way
  local in_2way=0
  if is_twoway_sync_path "$remote_dir"; then
    in_2way=1
  else
    for tw in "${TWOWAY_SYNC_PATHS[@]}"; do
      if [[ "$remote_dir" == "$tw"* ]]; then
        in_2way=1
        break
      fi
    done
  fi
  if [[ "$in_2way" -eq 0 ]]; then
    return
  fi

  echo ">> [Two-Way, last-modified] Listing: $remote_dir"
  local listing
  listing="$(list_remote_dir "$remote_dir")"

  # parse listing
  declare -A remote_files
  mapfile -t items < <(echo "$listing" | jq -c '.[]')
  for item_json in "${items[@]}"; do
    local path name size
    path="$(echo "$item_json" | jq -r '.path')"
    path="$(echo "$path" | sed 's:/*$::')"  # remove trailing slash
	name="$(echo "$item_json" | jq -r '.name')"
	size="$(echo "$item_json" | jq -r '.size // -1')"

	if (( size < 0 )); then
      # Directory => recurse
      two_way_sync_dir "$path" "$local_dir/$name"
    else
      # File => store in dictionary
      remote_files["$path"]="$name"
    fi
  done

  mkdir -p "$local_dir"

  #
  # local -> remote
  #
  find "$local_dir" -mindepth 1 -maxdepth 1 -type f \
    \( ! -name '*.old' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        local base
        base="$(basename "$f")"
        local remote_file_path="${remote_dir}/${base}"

        # If backup-only, skip upload
        if is_backup_only_path "$remote_dir"; then
          return
        fi

        local local_mtime
        local_mtime="$(stat_local_mtime "$f")"
        # If remote file exists
        if [[ -n "${remote_files["$remote_file_path"]+exists}" ]]; then
          # get remote mtime
          local rmt
          rmt="$(get_remote_mtime "$remote_file_path")"
          if (( local_mtime > rmt )); then
            echo "  local newer => upload $f => $remote_file_path"
            upload_file "$f" "$(dirname "$remote_file_path")"
          fi
        else
          # remote missing => upload
          echo "  remote missing => upload $f => $remote_file_path"
          upload_file "$f" "$(dirname "$remote_file_path")"
        fi
      done

  #
  # remote -> local
  #
  for rp in "${!remote_files[@]}"; do
    local rname="${remote_files["$rp"]}"
    local local_path="${local_dir}/${rname}"
    if [[ "$rname" == *.old ]]; then
      continue
    fi
    # get remote mtime
    local remote_mtime
    remote_mtime="$(get_remote_mtime "$rp")"

    if [[ ! -f "$local_path" ]]; then
      echo "  local missing => download $rp => $local_path"
      download_file "$rp" "$local_path"
    else
      # compare lastmod
      local local_mtime
      local_mtime="$(stat_local_mtime "$local_path")"
      if (( remote_mtime > local_mtime )); then
        echo "  remote newer => download $rp => $local_path"
        download_file "$rp" "$local_path"
      fi
    fi
  done

  # Recurse local subdirectories
  find "$local_dir" -mindepth 1 -maxdepth 1 -type d \
    \( ! -name '*.old' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' d; do
        local subbase
        subbase="$(basename "$d")"
        local cleaned
        cleaned="$(echo "$remote_dir" | sed 's:/*$::')"
        local r_sub="${cleaned}/${subbase}"
        two_way_sync_dir "$r_sub" "$d"
      done
}

###############################################################################
# download_file (using .part -> rename), skip on error
###############################################################################
function download_file() {
  local remote_path="$1"
  local local_path="$2"
  local expected_size="${3:-0}"

  # skip if .old
  if [[ "$remote_path" == *.old ]]; then
    echo "   [Skip .old] $remote_path"
    return
  fi
  if [[ "$local_path" == *.old ]]; then
    echo "   [Skip .old] $local_path"
    return
  fi

  local local_dir
  local_dir="$(dirname "$local_path")"
  mkdir -p "$local_dir"

  local tmp_file="${local_path}.part"
  local escaped
  escaped="$(urlencode_path "$remote_path")"

  local tries=0
  while (( tries < MAX_RETRIES )); do
    echo ">> Downloading: $remote_path -> $tmp_file"
    # Capture output in variable so we can parse curl error code
    curl -sS --connect-timeout "$CURL_CONNECT_TIMEOUT" \
         --max-time "$CURL_MAX_TIME" \
         -o "$tmp_file" \
         "${DOWNLOAD_ENDPOINT}?path=${escaped}"
    local ec=$?

    if [[ $ec -eq 0 ]]; then
      # Check size
      local actual_size
      actual_size="$(stat -c '%s' "$tmp_file" 2>/dev/null || echo 0)"
      if [[ "$expected_size" -gt 0 && "$actual_size" -ne "$expected_size" ]]; then
        echo "   Warning: size mismatch: expected=$expected_size got=$actual_size. Retrying..."
        rm -f "$tmp_file"
      else
        # Move from .part to final
        mv -f "$tmp_file" "$local_path"

		# Get remote mtime and set it on the downloaded file
		local remote_mtime
		remote_mtime="$(get_remote_mtime "$remote_path")"
		if [[ "$remote_mtime" -gt 0 ]]; then
			touch -d "@$remote_mtime" "$local_path"
		fi

        return
      fi
    else
      # If we get here, skip
      echo "   Warning: download_file() got curl error code=$ec. Possibly 404 or special char. Skipping file."
      rm -f "$tmp_file"
      return
    fi

    (( tries++ ))
    sleep 3
    wait_for_port_open
  done

  # If we tried multiple times, skip
  echo "   Skipping $remote_path after $MAX_RETRIES failures."
  rm -f "$tmp_file"
}

###############################################################################
# upload_file (using .part -> rename), skip on error
###############################################################################
function upload_file() {
  local local_path="$1"
  local remote_dir="$2"

  # Ensure the remote directory exists
  if ! create_remote_dir "$remote_dir"; then
    echo "   Error: Could not create remote directory: $remote_dir. Skipping upload."
    return 1
  fi

  local filename="$(basename "$local_path")"
  local part_name="${filename}.part"

  echo ">> Uploading: $local_path => $remote_dir/$part_name"

  local tries=0
  while (( tries < MAX_RETRIES )); do

    if curl -sS --fail \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -X POST \
      -F "path=${remote_dir}/" \
      -F "files[]=@\"${local_path}\";filename=\"${part_name}\"" \
      "${UPLOAD_ENDPOINT}"; then



      # Rename the uploaded .part file to its final name
      local old_path="${remote_dir}/${part_name}"
      local final_path="${remote_dir}/${filename}"
      move_remote_file_safely "$old_path" "$final_path"
      return 0
    else
      echo "   Warning: Upload failed for $local_path. Retrying..."
      (( tries++ ))
      sleep 3
    fi
  done

  echo "   Error:   Upload finally failed for $local_path => $remote_dir after $MAX_RETRIES attempts"
  return 1
}

###############################################################################
# FUNCTION: create_remote_dir
#   Checks if the remote directory exists and creates it if it does not.
###############################################################################
function create_remote_dir() {
  local remote_dir="$1"

  # Remove trailing slashes for consistency
  remote_dir="$(echo "$remote_dir" | sed 's:/*$::')"

  # Check if the remote directory already exists
  local escaped_dir
  escaped_dir="$(urlencode_path "$remote_dir")"
  local check_url="${LIST_ENDPOINT}?path=${escaped_dir}"

  echo ">> Checking if remote directory exists: $remote_dir"
  local status_code
  status_code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$check_url")"

  if [[ "$status_code" == "200" ]]; then
    echo "   Remote directory already exists: $remote_dir"
    return 0
  elif [[ "$status_code" == "404" ]]; then
    echo "   Remote directory does not exist, creating: $remote_dir"

    # Create the directory using the /create endpoint
    local create_url="${BASE_URL}/create"
    local create_status
    create_status="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      -X POST \
      -d "path=${escaped_dir}" \
      "$create_url")"

    if [[ "$create_status" == "200" ]]; then
      echo "   Successfully created remote directory: $remote_dir"
      return 0
    else
      echo "   ERROR: Failed to create remote directory $remote_dir (HTTP $create_status)"
      return 1
    fi
  else
    echo "   ERROR: Unexpected response checking remote directory $remote_dir (HTTP $status_code)"
    return 1
  fi
}


###############################################################################
# recursive_backup (one-way: remote -> local), skipping .old
###############################################################################
function recursive_backup() {
  local remote_dir="$1"
  local local_dir="$2"

  if is_excluded_path "$remote_dir"; then
    return
  fi

  echo ">> [Backup] Listing: $remote_dir"
  local listing
  listing="$(list_remote_dir "$remote_dir")"

  mapfile -t items < <(jq -c '.[]' <<<"$listing" 2>/dev/null)
  for item_json in "${items[@]}"; do
    local path name size
    path="$(echo "$item_json" | jq -r '.path')"
    name="$(echo "$item_json" | jq -r '.name')"
    size="$(echo "$item_json" | jq -r '.size // -1')"

    local local_dest="${local_dir}/${name}"
    if [[ "$size" -lt 0 ]]; then
      # directory
      recursive_backup "$path" "$local_dest"
    else
      # skip .old
      if [[ "$name" == *.old ]]; then
        continue
      fi
      # if local file exists with same size, skip
      if [[ -f "$local_dest" ]]; then
        local lsize
        lsize="$(stat -c '%s' "$local_dest" 2>/dev/null || echo 0)"
        if [[ "$lsize" -eq "$size" ]]; then
          # same size => skip
          continue
        fi
      fi
      download_file "$path" "$local_dest" "$size"
    fi
  done
}

###############################################################################
# MAIN
###############################################################################
function main() {
  echo
  echo
  echo "[$(TZ="$TZ" date)]"
  echo "==== RetroArch Sync (last-modified approach) ===="
  wait_for_port_open

  # 1) BACKUP ONLY
  echo "-> Step1: Backup Only"
  for bp in "${BACKUP_ONLY_PATHS[@]}"; do
    local local_dest="${LOCAL_BASE_DIR}${bp}"
    recursive_backup "$bp" "$local_dest"
  done

  # 2) INFINITE LOOP => TWO WAY
  echo "-> Step2: Two-Way Sync Loop"
  while true; do
    for twp in "${TWOWAY_SYNC_PATHS[@]}"; do
      echo "-> Two-Way Path: $twp"
      local local_dest="${LOCAL_BASE_DIR}${twp}"
      two_way_sync_dir "$twp" "$local_dest"
    done
    sleep "$SYNC_LOOP_INTERVAL"
  done
}

main "$@"
