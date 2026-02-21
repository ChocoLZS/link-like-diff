#!/usr/bin/env bash
# =============================================================================
# link-like-diff Automation Script
# =============================================================================
# Modules:
#   1. module_update  - run hailstorm --dbonly to fetch latest YAML data
#   2. module_git     - git add / commit / push, collect changed YAML list
#   3. module_images  - generate diff images via silicon for each changed file
#   4. module_notify  - send images via OneBot11 private msg, then forward to group
#
# Usage:
#   bash scripts/run.sh [--only-update|--only-git|--only-images|--only-notify]
#
# Environment variables (can be set in scripts/.env):
#   HAILSTORM_PATH   - path to hailstorm binary  (default: hailstorm)
#   SILICON_PATH     - path to silicon binary     (default: silicon)
#   ONEBOT_URL       - OneBot11 HTTP API base URL (required for notify)
#   ONEBOT_TOKEN     - Bearer token               (optional)
#   NOTIFY_USER_ID   - QQ number for private msgs (required for notify)
#   NOTIFY_GROUP_ID  - Group number for forward   (required for notify)
#   OUTPUT_DIR       - image output directory     (default: ./output)
#   WEB_UA           - User-Agent for version scraping
#   API_ENDPOINT     - login API to fetch res version
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Determine repo root (parent of scripts/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
HAILSTORM_PATH="${HAILSTORM_PATH:-hailstorm}"
SILICON_PATH="${SILICON_PATH:-silicon}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output}"
ONEBOT_URL="${ONEBOT_URL:-}"
ONEBOT_TOKEN="${ONEBOT_TOKEN:-}"
NOTIFY_USER_ID="${NOTIFY_USER_ID:-}"
NOTIFY_GROUP_ID="${NOTIFY_GROUP_ID:-}"
WEB_UA="${WEB_UA:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36}"
API_ENDPOINT="${API_ENDPOINT:-https://api.link-like-lovelive.app/v1/user/login}"
APPLE_URL="${APPLE_URL:-https://apps.apple.com/jp/app/link-like-%E3%83%A9%E3%83%96%E3%83%A9%E3%82%A4%E3%83%96-%E8%93%AE%E3%83%8E%E7%A9%BA%E3%82%B9%E3%82%AF%E3%83%BC%E3%83%AB%E3%82%A2%E3%82%A4%E3%83%89%E3%83%AB%E3%82%AF%E3%83%A9%E3%83%96/id1665027261}"
DUFS_URL="${DUFS_URL:-}"
DUFS_USER="${DUFS_USER:-}"
DUFS_PASS="${DUFS_PASS:-}"
DUFS_PATH="${DUFS_PATH:-images}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" >&2; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# State shared between modules
# ---------------------------------------------------------------------------
CHANGED_FILES=()    # populated by module_git or module_images (--only-images)
MESSAGE_IDS=()      # populated by module_notify send_private_msg calls
CLIENT_VERSION=""   # populated by fetch_versions
RES_VERSION=""      # populated by fetch_versions
declare -A IMAGE_URLS  # file -> uploaded HTTP URL, populated by module_images

# ---------------------------------------------------------------------------
# fetch_versions: get latest client version and resource version
# Sets CLIENT_VERSION and RES_VERSION globals
# ---------------------------------------------------------------------------
fetch_versions() {
  log_info "=== Version Detection ==="

  # 1. Get client version from Apple App Store
  log_info "Fetching client version from Apple App Store..."
  local apple_html
  apple_html=$(curl -s -H "User-Agent: $WEB_UA" "$APPLE_URL" 2>/dev/null || true)

  CLIENT_VERSION=$(echo "$apple_html" | \
    grep -o '"primarySubtitle":"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | \
    sed 's/"primarySubtitle":"\([^"]*\)"/\1/' | \
    head -1 || true)

  # Fallback: Google Play
  if [[ -z "$CLIENT_VERSION" ]]; then
    log_warn "Apple App Store failed, trying Google Play..."
    local google_html
    google_html=$(curl -s -H "User-Agent: $WEB_UA" \
      'https://play.google.com/store/apps/details?id=com.oddno.lovelive&hl=en' 2>/dev/null || true)
    CLIENT_VERSION=$(echo "$google_html" | \
      grep -o '\[\["[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"\]\]' | \
      sed -E 's/.*"([^"]+)".*/\1/' | \
      head -1 || true)
  fi

  if [[ -z "$CLIENT_VERSION" ]]; then
    log_error "Failed to detect client version."
    exit 1
  fi
  log_info "Client version: $CLIENT_VERSION"

  # 2. Get resource version from login API
  log_info "Fetching resource version from API..."
  local response
  response=$(curl -s -D - "$API_ENDPOINT" \
    -H "content-type: application/json" \
    -H "x-client-version: $CLIENT_VERSION" \
    -H "user-agent: inspix-android/$CLIENT_VERSION" \
    -H "x-res-version: R2503000" \
    -H "x-device-type: android" \
    -d '{"device_specific_id":"","player_id":"","version":1}' 2>/dev/null || true)

  RES_VERSION=$(echo "$response" | \
    grep -i "^x-res-version:" | \
    sed 's/^[Xx]-[Rr]es-[Vv]ersion: *//i' | \
    tr -d '\r\n' || true)

  if [[ -z "$RES_VERSION" ]]; then
    log_error "Failed to detect resource version."
    exit 1
  fi
  log_info "Resource version: $RES_VERSION"
}

# ---------------------------------------------------------------------------
# Module 1: Data Update
# ---------------------------------------------------------------------------
module_update() {
  log_info "=== Module 1: Data Update ==="

  if ! command -v "$HAILSTORM_PATH" &>/dev/null && [[ ! -x "$HAILSTORM_PATH" ]]; then
    log_error "hailstorm not found at: $HAILSTORM_PATH"
    log_error "Set HAILSTORM_PATH environment variable to the correct path."
    exit 1
  fi

  # Fetch versions first
  fetch_versions

  log_info "Running: $HAILSTORM_PATH --dbonly --client-version $CLIENT_VERSION --res-info $RES_VERSION"
  "$HAILSTORM_PATH" --dbonly --client-version "$CLIENT_VERSION" --res-info "$RES_VERSION"
  log_info "hailstorm update complete."

  # Sync masterdata/*.yaml -> repo root
  local masterdata_dir="$REPO_ROOT/masterdata"
  if [[ -d "$masterdata_dir" ]]; then
    log_info "Syncing masterdata/*.yaml -> repo root..."
    local count=0
    for f in "$masterdata_dir"/*.yaml; do
      [[ -f "$f" ]] || continue
      cp -f "$f" "$REPO_ROOT/$(basename "$f")"
      (( count++ )) || true
    done
    log_info "Synced $count YAML files to repo root."
    rm -rf "$masterdata_dir"
    log_info "Removed masterdata/ directory."
  else
    log_warn "masterdata/ directory not found after hailstorm run."
  fi
}

# ---------------------------------------------------------------------------
# Module 2: Git Detect / Commit / Push
# ---------------------------------------------------------------------------
module_git() {
  log_info "=== Module 2: Git Commit / Push ==="
  cd "$REPO_ROOT"

  # Stage only root-level YAML files; exclude build/tool dirs
  git add -- '*.yaml' ':!cache/' ':!masterdata/' ':!output/' ':!scripts/'

  # Check if there are any staged changes
  if git diff --cached --quiet; then
    log_info "No YAML changes staged. Skipping git commit."
    CHANGED_FILES=()
    return 0
  fi

  local commit_msg
  commit_msg="${RES_VERSION:-update: $(date '+%Y%m%d %H:%M:%S')}"

  git commit -m "$commit_msg"
  log_info "Committed: $commit_msg"

  git push
  log_info "Pushed to remote."

  # Collect changed YAML files from last commit vs previous
  mapfile -t CHANGED_FILES < <(git diff --name-only HEAD~1 HEAD -- '*.yaml' 2>/dev/null || true)

  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    log_info "No YAML files changed in this commit."
  else
    log_info "Changed YAML files (${#CHANGED_FILES[@]}):"
    for f in "${CHANGED_FILES[@]}"; do
      log_info "  - $f"
    done
  fi
}

# ---------------------------------------------------------------------------
# Module 3: Image Generation
# ---------------------------------------------------------------------------
module_images() {
  log_info "=== Module 3: Image Generation ==="
  cd "$REPO_ROOT"

  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    log_info "No changed YAML files to process. Skipping image generation."
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"

  if ! command -v "$SILICON_PATH" &>/dev/null && [[ ! -x "$SILICON_PATH" ]]; then
    log_error "silicon not found at: $SILICON_PATH"
    log_error "Set SILICON_PATH environment variable to the correct path."
    exit 1
  fi

  local generated=0
  local -a failed_files=()

  for file in "${CHANGED_FILES[@]}"; do
    local out_path="$OUTPUT_DIR/$(basename "$file").jpg"
    log_info "Generating image for: $file -> $out_path"

    local diff_content
    diff_content=$(git diff HEAD~1 HEAD -- "$file" 2>/dev/null || true)

    if [[ -z "$diff_content" ]]; then
      log_warn "No diff content for $file (possibly new file with no prior commit). Skipping."
      continue
    fi

    if echo "$diff_content" | "$SILICON_PATH" \
        -l diff \
        -f 'Noto Sans CJK JP' \
        -o "$out_path" \
        --window-title "$file"; then
      log_info "  Generated: $out_path"
      (( generated++ )) || true

      # Upload to dufs if configured
      if [[ -n "$DUFS_URL" ]]; then
        local img_url
        if img_url=$(upload_to_dufs "$out_path" "$file"); then
          IMAGE_URLS["$file"]="$img_url"
          log_info "  Uploaded: $img_url"
        else
          log_warn "  Upload failed for $file, will fall back to file:// path"
        fi
      fi
    else
      log_warn "  Failed to generate image for: $file"
      failed_files+=("$file")
    fi
  done

  log_info "Image generation complete. Success: $generated / ${#CHANGED_FILES[@]}"
  if [[ ${#failed_files[@]} -gt 0 ]]; then
    log_warn "Failed files: ${failed_files[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Helper: upload a file to dufs via HTTP PUT, outputs public URL on stdout
# ---------------------------------------------------------------------------
upload_to_dufs() {
  local local_path="$1"
  local yaml_file="$2"
  local filename
  filename="$(basename "$local_path")"
  local remote_url="${DUFS_URL%/}/${DUFS_PATH%/}/$filename"

  local -a curl_args=(-s -w "%{http_code}" -o /dev/null --http1.1 -T "$local_path" "$remote_url")
  if [[ -n "$DUFS_USER" || -n "$DUFS_PASS" ]]; then
    curl_args+=(--digest -u "${DUFS_USER}:${DUFS_PASS}")
  fi

  local http_code
  http_code=$(curl "${curl_args[@]}")

  if [[ "$http_code" =~ ^2 ]]; then
    echo "$remote_url"
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: make OneBot11 HTTP request
# Returns the full JSON response on stdout
# ---------------------------------------------------------------------------
onebot_request() {
  local endpoint="$1"
  local payload="$2"

  local url="${ONEBOT_URL%/}/$endpoint"
  local -a curl_args=(
    -s -X POST "$url"
    -H "Content-Type: application/json"
    -d "$payload"
  )

  if [[ -n "$ONEBOT_TOKEN" ]]; then
    curl_args+=(-H "Authorization: Bearer $ONEBOT_TOKEN")
  fi

  curl "${curl_args[@]}"
}

# ---------------------------------------------------------------------------
# Helper: send one private message containing filename + image
# Outputs the message_id on stdout; returns 1 on failure
# ---------------------------------------------------------------------------
send_file_to_private() {
  local file="$1"
  local img_path="$2"

  # Build image URI: use dufs HTTP URL if configured, otherwise file://
  local img_uri
  local filename
  filename="$(basename "$img_path")"
  if [[ -n "$DUFS_URL" ]]; then
    img_uri="${DUFS_URL%/}/${DUFS_PATH%/}/$filename"
  else
    img_uri="file://$(realpath "$img_path")"
  fi

  # Build message array: text segment + image segment
  local payload
  payload=$(printf '{"user_id":%s,"message":[{"type":"text","data":{"text":"[link-like-diff] 变更文件：%s\\n"}},{"type":"image","data":{"file":"%s"}}]}' \
    "$NOTIFY_USER_ID" "$file" "$img_uri")

  local response
  response=$(onebot_request "send_private_msg" "$payload")

  local status
  status=$(echo "$response" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ "$status" != "ok" ]]; then
    log_warn "send_private_msg failed for $file: $response"
    return 1
  fi

  # Extract message_id
  local msg_id
  msg_id=$(echo "$response" | grep -o '"message_id":[0-9-]*' | head -1 | cut -d: -f2)
  echo "$msg_id"
}

# ---------------------------------------------------------------------------
# Helper: send metadata summary as a private message
# Outputs the message_id on stdout; returns 1 on failure
# ---------------------------------------------------------------------------
send_metadata_to_private() {
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')

  # Build file list lines (real newlines here are fine; printf will output them)
  local file_list=""
  for f in "${CHANGED_FILES[@]}"; do
    file_list+="  • $f"$'\n'
  done

  # Build the full text with real newlines
  local text
  text=$(printf '[link-like-diff] 更新摘要\n━━━━━━━━━━━━━━━━━━\n🕐 时间：%s\n📦 客户端版本：%s\n🗂 资源版本：%s\n\n📄 变更文件（%d 个）：\n%s' \
    "$now" \
    "${CLIENT_VERSION:-unknown}" \
    "${RES_VERSION:-unknown}" \
    "${#CHANGED_FILES[@]}" \
    "$file_list")

  # Build JSON payload — must properly escape the text string.
  # Prefer jq (handles all edge cases); fall back to sed/awk manual escaping.
  local payload
  if command -v jq &>/dev/null; then
    payload=$(jq -n \
      --argjson uid "$NOTIFY_USER_ID" \
      --arg txt "$text" \
      '{"user_id":$uid,"message":[{"type":"text","data":{"text":$txt}}]}')
  else
    # Escape: backslashes → \\, double-quotes → \", then newlines → \n
    local escaped
    escaped=$(printf '%s' "$text" \
      | sed 's/\\/\\\\/g; s/"/\\"/g' \
      | awk 'NR>1{printf "\\n"}{printf "%s",$0}')
    payload=$(printf '{"user_id":%s,"message":[{"type":"text","data":{"text":"%s"}}]}' \
      "$NOTIFY_USER_ID" "$escaped")
  fi

  local response
  response=$(onebot_request "send_private_msg" "$payload")

  local status
  status=$(echo "$response" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ "$status" != "ok" ]]; then
    log_warn "send_private_msg (metadata) failed: $response"
    return 1
  fi

  local msg_id
  msg_id=$(echo "$response" | grep -o '"message_id":[0-9-]*' | head -1 | cut -d: -f2)
  echo "$msg_id"
}

# ---------------------------------------------------------------------------
# Helper: send group forward message using collected message_ids
# ---------------------------------------------------------------------------
send_group_forward() {
  local -a ids=("$@")

  if [[ ${#ids[@]} -eq 0 ]]; then
    log_warn "No message IDs to forward."
    return 0
  fi

  # Build nodes array: [{"type":"node","data":{"id":"<msg_id>"}}, ...]
  local nodes='['
  for i in "${!ids[@]}"; do
    [[ $i -gt 0 ]] && nodes+=','
    nodes+="{\"type\":\"node\",\"data\":{\"id\":${ids[$i]}}}"
  done
  nodes+=']'

  local payload
  payload=$(printf '{"group_id":%s,"messages":%s}' "$NOTIFY_GROUP_ID" "$nodes")

  local response
  response=$(onebot_request "send_group_forward_msg" "$payload")

  local status
  status=$(echo "$response" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ "$status" != "ok" ]]; then
    log_error "send_group_forward_msg failed: $response"
    return 1
  fi

  log_info "Group forward message sent successfully."
}

# ---------------------------------------------------------------------------
# Module 4: Notify via OneBot11
# ---------------------------------------------------------------------------
module_notify() {
  log_info "=== Module 4: Notify (OneBot11) ==="

  # Validate required env vars
  local missing=()
  [[ -z "$ONEBOT_URL" ]]      && missing+=("ONEBOT_URL")
  [[ -z "$NOTIFY_USER_ID" ]]  && missing+=("NOTIFY_USER_ID")
  [[ -z "$NOTIFY_GROUP_ID" ]] && missing+=("NOTIFY_GROUP_ID")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required environment variables: ${missing[*]}"
    log_error "Please set them in scripts/.env or export before running."
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    log_error "curl is required for notifications but was not found."
    exit 1
  fi

  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    log_info "No changed files – nothing to notify."
    return 0
  fi

  MESSAGE_IDS=()

  # Send metadata summary first
  log_info "Sending metadata summary message..."
  local meta_id
  if meta_id=$(send_metadata_to_private); then
    log_info "  metadata message_id: $meta_id"
    MESSAGE_IDS+=("$meta_id")
  else
    log_warn "  Failed to send metadata summary message"
  fi

  for file in "${CHANGED_FILES[@]}"; do
    local img_path="$OUTPUT_DIR/$(basename "$file").jpg"

    if [[ ! -f "$img_path" ]]; then
      log_warn "Image not found for $file ($img_path), skipping."
      continue
    fi

    log_info "Sending private message for: $file"
    local msg_id
    if msg_id=$(send_file_to_private "$file" "$img_path"); then
      log_info "  message_id: $msg_id"
      MESSAGE_IDS+=("$msg_id")
    else
      log_warn "  Failed to send private message for $file"
    fi
  done

  log_info "Sending group forward message (${#MESSAGE_IDS[@]} messages)..."
  send_group_forward "${MESSAGE_IDS[@]}"
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
main() {
  local mode="${1:-all}"

  case "$mode" in
    --only-update) module_update ;;
    --only-git)    module_git ;;
    --only-images)
      # In standalone image mode, compute CHANGED_FILES from last commit
      cd "$REPO_ROOT"
      mapfile -t CHANGED_FILES < <(git diff --name-only HEAD~1 HEAD -- '*.yaml' 2>/dev/null || true)
      module_images
      ;;
    --only-notify)
      # In standalone notify mode, compute CHANGED_FILES and assume images exist
      cd "$REPO_ROOT"
      mapfile -t CHANGED_FILES < <(git diff --name-only HEAD~1 HEAD -- '*.yaml' 2>/dev/null || true)
      fetch_versions
      module_notify
      ;;
    all|"")
      module_update
      module_git

      if [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
        module_images
        module_notify
      else
        log_info "No YAML changes detected. Done."
      fi
      ;;
    *)
      echo "Usage: $0 [--only-update|--only-git|--only-images|--only-notify]"
      exit 1
      ;;
  esac

  log_info "All done."
}

main "$@"
