#!/usr/bin/env bash
# The installer needs bash. The check comes before "set" so that a
# "curl ... | sh" gets this message instead of a parse error.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: this installer needs bash." >&2
  echo "       Run it with: bash opencode-jail-installer.sh" >&2
  exit 1
fi
set -euo pipefail

# opencode-jail-installer.sh — install the OpenCode 2 jail on this machine.
#
#   curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh | bash
#
# The installer takes no option. It checks the host requirements, writes the
# jail state, builds the image when it is missing and installs the launcher
# `opencode-jail` in ~/.local/bin.
#
# Everything else is done by the launcher itself:
#   opencode-jail --update                 new OpenCode, new Free Claude Code, new agents
#   opencode-jail --agents-update          new Agency Agents only
#   opencode-jail --fcc-refresh-models     test the models of the local FCC proxy
#   opencode-jail --help                   every option of the launcher
#
# The script never reads stdin, so it can be piped from curl.

JAIL_HOME="$HOME/.config/opencode-jail"
JAIL_IMAGE="${OPENCODE_JAIL_IMAGE:-opencode-jail:latest}"
JAIL_CONTAINERFILE="$JAIL_HOME/Containerfile"
WRAPPER_PATH="$HOME/.local/bin/opencode-jail"
AGENTS_DIR="$JAIL_HOME/opencode/agents"
FCC_DIR="$JAIL_HOME/fcc"

usage_installer() {
  cat <<EOF
opencode-jail-installer.sh — install the OpenCode 2 sandbox

Usage:
  curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh | bash
  curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh | bash -s -- --help
  bash opencode-jail-installer.sh

The installer takes no argument. It:
  - checks that Podman and git are available,
  - creates the jail state in $JAIL_HOME,
  - writes the image definition to $JAIL_CONTAINERFILE,
  - builds the image $JAIL_IMAGE when it is missing,
  - fetches the Agency Agents when none are installed yet,
  - installs the launcher $WRAPPER_PATH.

Everything else is done by the launcher:
  opencode-jail --help
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage_installer; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "       The installer takes no argument; the launcher does the rest." >&2
      echo "       See: opencode-jail --help" >&2
      exit 1 ;;
  esac
fi

command -v podman >/dev/null 2>&1 || {
  echo "ERROR: Podman is required. Install it first." >&2
  exit 1
}

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is required (the Agency Agents are installed from GitHub). Install it first." >&2
  exit 1
}

mkdir -p "$JAIL_HOME"

ensure_dirs() {
  mkdir -p "$JAIL_HOME"/{opencode,share,state,cache,npm,playwright,fcc}
  mkdir -p "$AGENTS_DIR"
  if [[ ! -f "$FCC_DIR/.env" ]]; then
    printf 'FCC_OPEN_BROWSER=false\n' > "$FCC_DIR/.env"
  fi
  touch "$JAIL_HOME/gitconfig"
  if [[ ! -s "$JAIL_HOME/gitconfig" ]] && [[ -s "$HOME/.gitconfig" ]]; then
    cp "$HOME/.gitconfig" "$JAIL_HOME/gitconfig"
  fi
}

# The image definition. It is written into the jail state and read back by
# `opencode-jail --update`, so there is exactly one definition.
write_containerfile() {
  local tmp="$JAIL_CONTAINERFILE.tmp.$$"
  cat > "$tmp" <<'CONTAINERFILE'
FROM node:22-bookworm

ARG HOST_UID=1000
ARG HOST_GID=1000

ENV OPENCODE_DISABLE_AUTOUPDATE=1
ENV DEBIAN_FRONTEND=noninteractive

RUN groupmod -g "$HOST_GID" --non-unique node \
 && usermod -u "$HOST_UID" --non-unique -g "$HOST_GID" node

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq python3 unzip findutils \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/opencode-jail/seed /workspace /home/node/.fcc \
 && chown -R node:node /opt/opencode-jail /workspace /home/node/.fcc

USER node

RUN curl -fsSL https://opencode.ai/v2/install | bash
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN ~/.local/bin/uv tool install free-claude-code

RUN printf '%s\n' '{"plugins":["@cortexkit/opencode-magic-context@latest"],"compaction":{"auto":false}}' \
      > /opt/opencode-jail/seed/opencode.json

RUN printf '%s\n' \
      '#!/bin/bash' \
      'set -e' \
      'CFG="/home/node/.config/opencode"' \
      'mkdir -p "$CFG/agents"' \
      '[ -f "$CFG/opencode.json" ] || cp /opt/opencode-jail/seed/opencode.json "$CFG/opencode.json"' \
      'if [ "${JAIL_START_FCC_SERVER:-0}" = "1" ]; then' \
      '  if curl -s -o /dev/null --max-time 1 --connect-timeout 1 http://127.0.0.1:8082/ 2>/dev/null; then' \
      '    echo "[opencode-jail] Using existing fcc-server on :8082" >&2' \
      '  else' \
      '    echo "[opencode-jail] Starting fcc-server..." >&2' \
      '    fcc-server > /tmp/fcc-server.log 2>&1 &' \
      '    FCC_PID=$!' \
      '    trap "kill $FCC_PID 2>/dev/null || true" EXIT' \
      '    for i in $(seq 1 30); do' \
      '      if curl -s -o /dev/null --max-time 1 --connect-timeout 1 http://127.0.0.1:8082/ 2>/dev/null; then' \
      '        echo "[opencode-jail] fcc-server ready. Admin: http://localhost:8082/admin" >&2' \
      '        break' \
      '      fi' \
      '      sleep 1' \
      '    done' \
      '    if ! kill -0 $FCC_PID 2>/dev/null; then' \
      '      echo "[opencode-jail] fcc-server failed to start. Log:" >&2' \
      '      cat /tmp/fcc-server.log >&2' \
      '      exit 1' \
      '    fi' \
      '  fi' \
      'fi' \
      'exec "${OPENCODE_BIN:-/home/node/.opencode/bin/opencode}" "$@"' \
      > /opt/opencode-jail/init.sh \
 && chmod +x /opt/opencode-jail/init.sh

ENV PATH="/home/node/.opencode/bin:/home/node/.local/bin:/home/node/.local/share/uv/tools/free-claude-code/bin:${PATH}"

WORKDIR /workspace
ENTRYPOINT ["/opt/opencode-jail/init.sh"]
CONTAINERFILE
  mv "$tmp" "$JAIL_CONTAINERFILE"
}

# The launcher. It owns the whole life of the jail: the launch itself, the
# maintenance of the image, the Agency Agents and the Free Claude Code proxy.
write_wrapper() {
  local tmp="$WRAPPER_PATH.tmp.$$"
  mkdir -p "$(dirname "$WRAPPER_PATH")"
  cat > "$tmp" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

# opencode-jail — run OpenCode 2 in a sandboxed Podman container and
# maintain the jail (image, Agency Agents, Free Claude Code proxy).
#
# This file is written by opencode-jail-installer.sh — do not edit it by hand.

JAIL_HOME="$HOME/.config/opencode-jail"
JAIL_IMAGE="${OPENCODE_JAIL_IMAGE:-opencode-jail:latest}"
JAIL_CONTAINERFILE="$JAIL_HOME/Containerfile"
ADMIN_CONTAINER="opencode-jail-fcc-admin"
ADMIN_URL="http://localhost:8082/admin"
FCC_PORT=8082

# --- Agency Agents ------------------------------------------------------------
# The agents are installed on the host, not baked into the image: the jail
# mounts ~/.config/opencode-jail/opencode into the container, so the agents
# live there and stay up to date without a rebuild.
AGENCY_REPO_URL="https://github.com/msitarzewski/agency-agents.git"
AGENCY_DIR="$JAIL_HOME/agency-agents"
AGENTS_DIR="$JAIL_HOME/opencode/agents"

# --- Free Claude Code (FCC) ---------------------------------------------------
# The model refresh runs inside the jail image (it has curl and jq), so the
# host needs nothing beyond Podman for it.
FCC_DIR="$JAIL_HOME/fcc"
FCC_ENV_FILE="$FCC_DIR/.env"
FCC_MODELS_FILE="$FCC_DIR/fcc-models.txt"
FCC_ALL_MODELS_FILE="$FCC_DIR/fcc-all-models.txt"
FCC_REFRESH_SCRIPT="$FCC_DIR/.refresh-models.sh"
FCC_MODEL_COUNT="${FCC_MODEL_COUNT:-50}"
FCC_ALL_MODEL_COUNT="${FCC_ALL_MODEL_COUNT:-}"
FCC_REQUEST_TIMEOUT="${FCC_REQUEST_TIMEOUT:-45}"
FCC_MAX_FALLBACKS="${FCC_MAX_FALLBACKS:-120}"
FCC_BASE_URL="${FCC_BASE_URL:-http://127.0.0.1:8082}"

usage() {
  cat <<EOF
opencode-jail — launch OpenCode 2 in a sandboxed Podman container

Usage:
  opencode-jail [OPTIONS] [WORKSPACE]

Arguments:
  WORKSPACE              Project directory (default: current directory)

Jail maintenance:
      --update                 Rebuild the image (OpenCode, FCC) and refresh the agents
      --agents-update          Refresh the Agency Agents only
      --fcc-refresh-models        Test $FCC_MODEL_COUNT random models of the local FCC proxy
      --fcc-refresh-all-models    Test all models from all providers (random order)

Free Claude Code:
      --fcc                    Launch through Free Claude Code (auto-starts fcc-server)
      --fcc-admin              Start fcc-server and open the admin UI in your browser
      --fcc-restart            Restart fcc-server to apply config changes from admin

Other:
  -w, --workspace <dir>  Project directory (same as positional argument)
  -h, --help             Show this help

Examples:
  opencode-jail                          Current directory, plain OpenCode
  opencode-jail ~/Projects/myapp         Specific project, plain OpenCode
  opencode-jail --fcc .                  With FCC proxy (ephemeral fcc-server)
  opencode-jail --fcc-admin              Configure FCC providers and keys
  opencode-jail --fcc-restart            Apply config changes saved in admin
  opencode-jail --update                 New OpenCode, new Free Claude Code, new agents
  opencode-jail --agents-update          New Agency Agents only
  opencode-jail --fcc-refresh-models     New fallback list for the proxy (random 50)
  opencode-jail --fcc-refresh-all-models New fallback list for the proxy (all models, random order)

FCC workflow:
  1. opencode-jail --fcc-admin           First-time setup
  2. opencode-jail --fcc <workspace>     Use the proxy
  3. (change config in admin) opencode-jail --fcc-restart
  4. opencode-jail --fcc <workspace>     Use the updated config

FCC admin UI: $ADMIN_URL
EOF
  exit "${1:-0}"
}

# --- the jail state ----------------------------------------------------------
ensure_state() {
  mkdir -p "$JAIL_HOME"/{opencode,share,state,cache,npm,playwright,fcc}
  [[ -f "$FCC_ENV_FILE" ]] || printf 'FCC_OPEN_BROWSER=false\n' > "$FCC_ENV_FILE"
  [[ -f "$JAIL_HOME/gitconfig" ]] || : > "$JAIL_HOME/gitconfig"
}

require_image() {
  podman image exists "$JAIL_IMAGE" 2>/dev/null || {
    echo "ERROR: image $JAIL_IMAGE not built. Run: opencode-jail --update" >&2
    exit 1
  }
}

# --- the image ----------------------------------------------------------------
# The image definition lives in the jail state; the installer writes it.
build_image() {
  if [[ ! -f "$JAIL_CONTAINERFILE" ]]; then
    echo "ERROR: $JAIL_CONTAINERFILE is missing." >&2
    echo "       Run the installer again: bash opencode-jail-installer.sh" >&2
    exit 1
  fi
  echo "==> Building $JAIL_IMAGE (latest OpenCode 2, FCC)"
  if ! podman build \
    --build-arg "HOST_UID=$(id -u)" \
    --build-arg "HOST_GID=$(id -g)" \
    -t "$JAIL_IMAGE" \
    -f "$JAIL_CONTAINERFILE" \
    "$JAIL_HOME"; then
    echo "ERROR: the image $JAIL_IMAGE could not be built." >&2
    exit 1
  fi
}

# --- Agency Agents: clone or update the upstream repository and install the
# converted OpenCode agents into the jail state directory. The jail mounts
# that directory into the container, so no image rebuild is needed.
update_agents() {
  command -v git >/dev/null 2>&1 || {
    echo "ERROR: git is required (the Agency Agents are installed from GitHub). Install it first." >&2
    return 1
  }

  echo "==> Refreshing the Agency Agents"
  if [[ ! -d "$AGENCY_DIR/.git" ]]; then
    rm -rf "$AGENCY_DIR"
    echo "    -> cloning $AGENCY_REPO_URL"
    # The stdin of the installer can be a pipe (curl | bash): no child may
    # read from it.
    if ! git clone --depth 1 "$AGENCY_REPO_URL" "$AGENCY_DIR" </dev/null; then
      echo "ERROR: could not clone $AGENCY_REPO_URL" >&2
      return 1
    fi
  else
    echo "    -> updating the checkout in $AGENCY_DIR"
    if ! git -C "$AGENCY_DIR" fetch --depth 1 origin main; then
      echo "ERROR: could not fetch $AGENCY_REPO_URL" >&2
      return 1
    fi
    if ! git -C "$AGENCY_DIR" reset --hard FETCH_HEAD; then
      echo "ERROR: could not reset $AGENCY_DIR" >&2
      return 1
    fi
  fi

  echo "    -> converting the agents for OpenCode"
  if ! ( cd "$AGENCY_DIR" && ./scripts/convert.sh --tool opencode >/dev/null ); then
    echo "ERROR: the conversion of the Agency Agents failed." >&2
    return 1
  fi

  rm -rf "$AGENTS_DIR"
  mkdir -p "$AGENTS_DIR"
  local file base target index
  while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    target="$AGENTS_DIR/$base"
    index=1
    while [[ -e "$target" ]]; do
      target="$AGENTS_DIR/${base%.md}-$index.md"
      index=$((index + 1))
    done
    cp "$file" "$target"
  done < <(find "$AGENCY_DIR/integrations/opencode" -type f -name '*.md' ! -name 'README.md' -print0)

  local count
  count="$(find "$AGENTS_DIR" -maxdepth 1 -name '*.md' | wc -l)"
  if [[ "$count" -eq 0 ]]; then
    echo "ERROR: no agent file was produced from $AGENCY_REPO_URL" >&2
    return 1
  fi
  echo "    -> $count agent file(s) installed in $AGENTS_DIR"
}

# --- Free Claude Code: test the models of the local proxy ---------------------
# The work happens inside the jail image, which has curl and jq; the host only
# needs Podman. The script is mounted into the container together with the
# FCC configuration directory, so it reads and writes the same files the
# admin UI uses.
write_fcc_refresh_script() {
  mkdir -p "$FCC_DIR"
  local tmp="$FCC_REFRESH_SCRIPT.tmp.$$"
  cat > "$tmp" <<'REFRESH'
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-random}"
FCC_DIR="${FCC_DIR:-/fcc}"
ENV_FILE="$FCC_DIR/.env"
MODELS_FILE="$FCC_DIR/fcc-models.txt"
ALL_MODELS_FILE="$FCC_DIR/fcc-all-models.txt"
BASE_URL="${FCC_BASE_URL:-http://127.0.0.1:8082}"
MODEL_COUNT="${FCC_MODEL_COUNT:-50}"
ALL_MODEL_COUNT="${FCC_ALL_MODEL_COUNT:-}"
REQUEST_TIMEOUT="${FCC_REQUEST_TIMEOUT:-45}"
MAX_FALLBACKS="${FCC_MAX_FALLBACKS:-120}"

# The proxy token of the managed configuration. The proxy only checks it when
# PROXY_AUTH_ENABLED is set, sending it is harmless in every case.
auth_token() {
  local token=""
  if [[ -f "$ENV_FILE" ]]; then
    token="$(grep -m1 '^ANTHROPIC_AUTH_TOKEN=' "$ENV_FILE" | cut -d= -f2- | head -n1)"
    token="${token%\"}"; token="${token#\"}"
    token="${token%\'}"; token="${token#\'}"
  fi
  printf '%s' "${token:-freecc}"
}

TOKEN="$(auth_token)"

fetch_models() {
  curl -sS --max-time "$REQUEST_TIMEOUT" \
    -H "x-api-key: $TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    "$BASE_URL/v1/models" 2>/dev/null | jq -r '
      (if type == "array" then . else (.data // .models // []) end)
      | map(if type == "string" then . else (.id // .model // .name // .slug // "") end)
      | map(select(length > 0))
      | map(sub("^anthropic/"; "") | sub("^claude-3-freecc-no-thinking/"; ""))
      | map(select(test("^[^/]+/.+$")))
      | unique
      | .[]
    ' 2>/dev/null
}

# Test one model with a minimal request; returns 0 when the model works.
test_model() {
  local model="$1" out status
  out="$(mktemp)"
  status="$(curl -sS --max-time "$REQUEST_TIMEOUT" -o "$out" -w '%{http_code}' \
    -H "x-api-key: $TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" \
    "$BASE_URL/v1/messages" 2>/dev/null)" || status="000"

  local result=1
  if [[ "$status" == "200" ]] && ! grep -q '"type":"error"' "$out"; then
    result=0
  fi
  rm -f "$out"
  return "$result"
}

write_models() {
  local file="$1"; shift
  local model
  : > "$file.tmp"
  for model in "$@"; do
    [[ -n "$model" ]] && printf '%s\n' "$model" >> "$file.tmp"
  done
  mv "$file.tmp" "$file"
}

# Rewrite MODEL_FALLBACKS in the managed configuration. The primary MODEL
# stays untouched and is never repeated in the fallback list.
update_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found; nothing to update." >&2
    return 1
  fi

  local primary=""
  primary="$(grep -m1 '^MODEL=' "$ENV_FILE" | cut -d= -f2- | head -n1)"
  primary="${primary%\"}"; primary="${primary#\"}"
  primary="${primary%\'}"; primary="${primary#\'}"

  local -a candidates=()
  local model
  for model in "$@"; do
    [[ -n "$model" ]] || continue
    [[ "$model" == "$primary" ]] && continue
    candidates+=("$model")
  done

  local -a entries=()
  while IFS= read -r model; do
    [[ -n "$model" ]] && entries+=("$model")
  done < <(printf '%s\n' "${candidates[@]}" | shuf | head -n "$MAX_FALLBACKS")

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "ERROR: no working model; MODEL_FALLBACKS was left untouched." >&2
    return 1
  fi

  # The .env stores the value in double quotes with escaped inner quotes.
  local json
  json="$(printf '%s\n' "${entries[@]}" | jq -R . \
    | jq -s '[.[] | {model: ., reasoning: "inherit", api_key_number: 1}]' | jq -c .)"
  json="${json//\"/\\\"}"

  local backup tmp
  backup="$ENV_FILE.$(date +%Y%m%d-%H%M%S).bak"
  cp -p "$ENV_FILE" "$backup"
  tmp="$ENV_FILE.tmp"

  # A shell loop is used on purpose: awk would interpret the backslashes of
  # the escaped JSON value.
  local -a new_lines=()
  local line replaced=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*MODEL_FALLBACKS[[:space:]]*= ]]; then
      new_lines+=("MODEL_FALLBACKS=\"$json\"")
      replaced=1
    else
      new_lines+=("$line")
    fi
  done < "$ENV_FILE"
  if [[ $replaced -eq 0 ]]; then
    new_lines+=("MODEL_FALLBACKS=\"$json\"")
  fi
  printf '%s\n' "${new_lines[@]}" > "$tmp"

  chmod --reference="$ENV_FILE" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"

  echo "    -> MODEL_FALLBACKS in $ENV_FILE rewritten with ${#entries[@]} model(s)"
  echo "    -> backup: $backup"
  [[ -n "$primary" ]] && echo "    -> MODEL ($primary) kept as the primary model"
  return 0
}

if ! curl -sS --max-time 15 -o /dev/null \
    -H "x-api-key: $TOKEN" \
    "$BASE_URL/v1/models" 2>/dev/null; then
  echo "ERROR: cannot reach the Free Claude Code proxy at $BASE_URL." >&2
  echo "       Start it with: opencode-jail --fcc-admin" >&2
  exit 1
fi

echo "==> Fetching the model list from $BASE_URL"
models=()
while IFS= read -r model; do
  [[ -n "$model" ]] && models+=("$model")
done < <(fetch_models)

if [[ ${#models[@]} -eq 0 ]]; then
  echo "ERROR: no models found at $BASE_URL/v1/models." >&2
  echo "       Is Free Claude Code running? Start it with: opencode-jail --fcc-admin" >&2
  exit 1
fi

# Count unique providers (prefix before first /)
provider_count=$(printf '%s\n' "${models[@]}" | cut -d'/' -f1 | sort -u | wc -l)
echo "    -> ${#models[@]} routable model(s) from ${provider_count} provider(s)"

if [[ "$MODE" == "random" ]]; then
  mapfile -t models < <(printf '%s\n' "${models[@]}" | shuf | head -n "$MODEL_COUNT")
  echo "    -> testing ${#models[@]} random model(s)"
  out_file="$MODELS_FILE"
elif [[ "$MODE" == "all-random" ]]; then
  if [[ -n "$ALL_MODEL_COUNT" ]]; then
    mapfile -t models < <(printf '%s\n' "${models[@]}" | shuf | head -n "$ALL_MODEL_COUNT")
    echo "    -> testing ${#models[@]} random model(s) from all providers (limited to $ALL_MODEL_COUNT)"
  else
    mapfile -t models < <(printf '%s\n' "${models[@]}" | shuf)
    echo "    -> testing all ${#models[@]} model(s) from all providers (random order)"
  fi
  out_file="$ALL_MODELS_FILE"
else
  echo "    -> testing all ${#models[@]} model(s)"
  out_file="$ALL_MODELS_FILE"
fi

working=()
index=0
failed=0
total=${#models[@]}
for model in "${models[@]}"; do
  index=$((index + 1))
  if test_model "$model"; then
    working+=("$model")
    printf '    [%d/%d] %s OK\n' "$index" "$total" "$model"
  else
    failed=$((failed + 1))
    printf '    [%d/%d] %s FAIL\n' "$index" "$total" "$model"
  fi
  # Keep the file current, so an interrupted run still has a result.
  write_models "$out_file" "${working[@]}"
done

echo ""
echo "    -> working models: ${#working[@]}   failed: $failed"
if [[ ${#working[@]} -eq 0 ]]; then
  echo "ERROR: no working model found; the configuration was left untouched." >&2
  exit 1
fi
echo "    -> working models written to $out_file"
update_env "${working[@]}"
REFRESH
  chmod +x "$tmp"
  mv "$tmp" "$FCC_REFRESH_SCRIPT"
}

refresh_fcc_models() {
  local mode="$1"
  require_image
  mkdir -p "$FCC_DIR"
  write_fcc_refresh_script
  echo "==> Testing the models of the local Free Claude Code proxy ($mode)"
  podman run --rm --network=host --userns=keep-id \
    -e "FCC_BASE_URL=$FCC_BASE_URL" \
    -e "FCC_MODEL_COUNT=$FCC_MODEL_COUNT" \
    -e "FCC_ALL_MODEL_COUNT=$FCC_ALL_MODEL_COUNT" \
    -e "FCC_REQUEST_TIMEOUT=$FCC_REQUEST_TIMEOUT" \
    -e "FCC_MAX_FALLBACKS=$FCC_MAX_FALLBACKS" \
    -v "$FCC_DIR:/fcc:z" \
    --entrypoint /bin/bash \
    "$JAIL_IMAGE" "/fcc/.refresh-models.sh" "$mode"
}

# --- the Free Claude Code proxy -----------------------------------------------
fcc_server_running() {
  curl -s -o /dev/null --max-time 1 --connect-timeout 1 "http://127.0.0.1:${FCC_PORT}/" 2>/dev/null
}

fcc_container_exists() {
  podman container exists "$ADMIN_CONTAINER" >/dev/null 2>&1
}

fcc_container_running() {
  podman inspect --format '{{.State.Running}}' "$ADMIN_CONTAINER" 2>/dev/null | grep -q '^true$'
}

# The id of the server instance that currently serves the port. It changes
# with every start of a new server, so it proves that a fresh server took
# over the port.
fcc_instance_id() {
  curl -s --max-time 3 "http://127.0.0.1:${FCC_PORT}/admin/api/status" 2>/dev/null \
    | sed -n 's/.*"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# The settings the server says it still needs a restart for.
fcc_pending_fields() {
  curl -s --max-time 3 "http://127.0.0.1:${FCC_PORT}/admin/api/status" 2>/dev/null \
    | sed -n 's/.*"pending_fields"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
    | head -n1 | sed 's/", "/, /g; s/^"//; s/"$//'
}

start_fcc_container() {
  podman rm -f "$ADMIN_CONTAINER" >/dev/null 2>&1 || true
  if ! podman run -d \
    --name "$ADMIN_CONTAINER" \
    --network=host \
    --userns=keep-id \
    -v "$JAIL_HOME/fcc:/home/node/.fcc:z" \
    --entrypoint /bin/bash \
    "$JAIL_IMAGE" -c 'exec fcc-server' >/dev/null; then
    echo "[opencode-jail] ERROR: could not start the container $ADMIN_CONTAINER." >&2
    return 1
  fi
}

# Stop the managed container and make sure it is really gone.
stop_fcc_container() {
  if podman container exists "$ADMIN_CONTAINER" 2>/dev/null; then
    podman stop -t 5 "$ADMIN_CONTAINER" >/dev/null 2>&1 || true
    podman rm -f "$ADMIN_CONTAINER" >/dev/null 2>&1 || true
  fi
  local i
  for ((i=0; i<20; i++)); do
    podman container exists "$ADMIN_CONTAINER" 2>/dev/null || return 0
    sleep 0.5
  done
  return 1
}

# The state of the managed container ("running", "exited", ...).
fcc_container_state() {
  podman inspect --format '{{.State.Status}}' "$ADMIN_CONTAINER" 2>/dev/null || true
}

# The jail sessions (a running OpenCode in a container of the jail image).
# Such a session can run its own fcc-server and hold the port with a server
# that still runs the old configuration. They are recognised by the entry
# point of the image, the admin container uses /bin/bash instead.
jail_sessions() {
  local id name entrypoint
  while read -r id name; do
    [[ -n "$id" ]] || continue
    entrypoint="$(podman inspect --format '{{join .Config.Entrypoint " "}}' "$id" 2>/dev/null || true)"
    case "$entrypoint" in
      *init.sh*) printf '%s %s\n' "$id" "$name" ;;
    esac
  done < <(podman ps --filter "ancestor=$JAIL_IMAGE" --format '{{.ID}} {{.Names}}' 2>/dev/null)
}

# Wait until nothing answers on the port any more.
wait_for_free_port() {
  local i
  for ((i=0; i<30; i++)); do
    fcc_server_running || return 0
    sleep 0.5
  done
  return 1
}

wait_for_fcc() {
  local tries="${1:-60}" i state
  for ((i=0; i<tries; i++)); do
    # The server process died: waiting for the port would be pointless.
    state="$(fcc_container_state)"
    case "$state" in
      exited|stopped|dead) return 1 ;;
    esac
    fcc_server_running && return 0
    sleep 1
  done
  return 1
}

print_fcc_logs() {
  podman logs --tail 30 "$ADMIN_CONTAINER" 2>&1 || true
}

open_browser() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 &
  elif command -v sensible-browser >/dev/null 2>&1; then
    sensible-browser "$url" >/dev/null 2>&1 &
  else
    return 1
  fi
}

# Start the managed fcc-server and make sure it really serves the port.
start_fcc_server() {
  echo "[opencode-jail] Starting the fcc-server..."
  if ! start_fcc_container; then
    return 1
  fi
  if ! wait_for_fcc 60; then
    echo "[opencode-jail] fcc-server failed to start. Logs:" >&2
    print_fcc_logs >&2
    return 1
  fi
  return 0
}

# Restart the managed fcc-server so that it reads the configuration that was
# saved in the admin UI. Every server that holds the port is stopped first:
# a jail session that runs its own fcc-server would keep the old
# configuration alive otherwise.
restart_fcc_server() {
  local before_id after_id pending
  before_id="$(fcc_instance_id || true)"

  echo "[opencode-jail] Stopping the managed fcc-server..."
  if ! stop_fcc_container; then
    echo "[opencode-jail] ERROR: the container $ADMIN_CONTAINER could not be removed." >&2
    return 1
  fi

  if ! wait_for_free_port; then
    local id name
    while read -r id name; do
      [[ -n "$id" ]] || continue
      echo "[opencode-jail] Stopping the jail session $name ($id): it runs an fcc-server with the old configuration."
      podman stop -t 5 "$id" >/dev/null 2>&1 || true
    done < <(jail_sessions)
    if ! wait_for_free_port; then
      echo "[opencode-jail] ERROR: port $FCC_PORT is still in use by a process outside the jail." >&2
      return 1
    fi
  fi

  if ! start_fcc_server; then
    return 1
  fi

  after_id="$(fcc_instance_id || true)"
  if [[ -n "$before_id" && -n "$after_id" && "$before_id" == "$after_id" ]]; then
    echo "[opencode-jail] ERROR: the server on port $FCC_PORT still runs the old instance ($before_id)." >&2
    return 1
  fi

  echo "[opencode-jail] fcc-server restarted (instance ${after_id:-unknown})."
  pending="$(fcc_pending_fields || true)"
  if [[ -n "$pending" ]]; then
    echo "[opencode-jail] Settings that still wait for a restart: $pending"
  fi
  return 0
}

# --- the options --------------------------------------------------------------
USE_FCC=0
FCC_ADMIN=0
FCC_RESTART=0
UPDATE=0
AGENTS_UPDATE=0
FCC_REFRESH_MODELS=0
FCC_REFRESH_ALL_MODELS=0
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      [[ -n "${2:-}" ]] || { echo "ERROR: $1 requires a path argument" >&2; exit 1; }
      WORKSPACE="$2"; shift 2 ;;
    --fcc)         USE_FCC=1; shift ;;
    --fcc-admin)   FCC_ADMIN=1; shift ;;
    --fcc-restart) FCC_RESTART=1; shift ;;
    --update)      UPDATE=1; shift ;;
    --agents-update) AGENTS_UPDATE=1; shift ;;
    --fcc-refresh-models) FCC_REFRESH_MODELS=1; shift ;;
    --fcc-refresh-all-models) FCC_REFRESH_ALL_MODELS=1; shift ;;
    -h|--help)     usage 0 ;;
    -*)            echo "ERROR: unknown option: $1" >&2; usage 1 ;;
    *)             WORKSPACE="$1"; shift ;;
  esac
done

ensure_state

# --- --update: rebuild the image and refresh the agents ----------------------
if [[ $UPDATE -eq 1 ]]; then
  build_image
  update_agents
fi

# --- --agents-update: refresh the Agency Agents only -------------------------
if [[ $AGENTS_UPDATE -eq 1 ]]; then
  update_agents
fi

# --- --fcc-refresh-models: test the models of the local proxy ----------------
if [[ $FCC_REFRESH_MODELS -eq 1 ]]; then
  refresh_fcc_models random
fi

if [[ $FCC_REFRESH_ALL_MODELS -eq 1 ]]; then
  refresh_fcc_models all-random
fi

if [[ $UPDATE -eq 1 || $AGENTS_UPDATE -eq 1 || $FCC_REFRESH_MODELS -eq 1 || $FCC_REFRESH_ALL_MODELS -eq 1 ]]; then
  exit 0
fi

# --- --fcc-admin: ensure fcc-server is up, open browser, exit ---------------
if [[ $FCC_ADMIN -eq 1 ]]; then
  require_image
  if fcc_server_running; then
    if fcc_container_running; then
      echo "[opencode-jail] fcc-server already running (managed container)"
    else
      echo "[opencode-jail] fcc-server already running on :$FCC_PORT (not managed by opencode-jail)"
      echo "[opencode-jail] It keeps its own configuration in memory; run --fcc-restart to apply new settings."
    fi
  else
    if ! start_fcc_server; then
      exit 1
    fi
  fi

  echo "[opencode-jail] Admin UI: $ADMIN_URL"
  if open_browser "$ADMIN_URL"; then
    echo "[opencode-jail] Browser opened."
  else
    echo "[opencode-jail] Open this URL in your browser: $ADMIN_URL"
  fi
  echo
  echo "[opencode-jail] Configure providers and keys, then run:"
  echo "  opencode-jail --fcc <workspace>"
  echo
  echo "[opencode-jail] Container: $ADMIN_CONTAINER"
  echo "[opencode-jail] To stop it: podman stop $ADMIN_CONTAINER"
  exit 0
fi

# --- --fcc-restart: recreate the fcc-server container ---------------------
if [[ $FCC_RESTART -eq 1 ]]; then
  require_image
  if ! restart_fcc_server; then
    exit 1
  fi
  echo "[opencode-jail] Config applied. If opencode is already running, restart it too."
  exit 0
fi

# --- Normal launch ------------------------------------------------------
require_image

WORKSPACE="${WORKSPACE:-$PWD}"
[[ -d "$WORKSPACE" ]] || { echo "ERROR: workspace not found: $WORKSPACE" >&2; exit 1; }
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"

if [[ "$WORKSPACE" == "/" || "$WORKSPACE" == "$HOME" || "$HOME" == "$WORKSPACE"/* ]]; then
  echo "ERROR: refusing workspace $WORKSPACE (choose a project subdirectory)" >&2
  exit 1
fi

if [[ $USE_FCC -eq 1 ]]; then
  OPENCODE_BIN=/home/node/.local/bin/fcc-opencode
  START_FCC=1
  EXTRA_ENV=()
else
  OPENCODE_BIN=/home/node/.opencode/bin/opencode
  START_FCC=0
  EXTRA_ENV=(-e "OPENCODE_CONFIG_CONTENT={}")
fi

exec podman run --rm -it \
  --network=host \
  --userns=keep-id \
  "${EXTRA_ENV[@]}" \
  -e "OPENCODE_BIN=$OPENCODE_BIN" \
  -e "JAIL_START_FCC_SERVER=$START_FCC" \
  -v "$WORKSPACE:/workspace:z" \
  -v "$JAIL_HOME/opencode:/home/node/.config/opencode:z" \
  -v "$JAIL_HOME/share:/home/node/.local/share/opencode:z" \
  -v "$JAIL_HOME/state:/home/node/.local/state/opencode:z" \
  -v "$JAIL_HOME/cache:/home/node/.cache/opencode:z" \
  -v "$JAIL_HOME/npm:/home/node/.npm:z" \
  -v "$JAIL_HOME/playwright:/home/node/.cache/ms-playwright:z" \
  -v "$JAIL_HOME/fcc:/home/node/.fcc:z" \
  -v "$JAIL_HOME/gitconfig:/home/node/.gitconfig:ro,z" \
  -w /workspace \
  "$JAIL_IMAGE" "$@"
WRAPPER
  chmod +x "$tmp"
  mv "$tmp" "$WRAPPER_PATH"
}

# --- install ------------------------------------------------------------------
echo "==> Creating the jail state in $JAIL_HOME"
ensure_dirs

echo "==> Writing the image definition to $JAIL_CONTAINERFILE"
write_containerfile

echo "==> Installing the launcher $WRAPPER_PATH"
write_wrapper

if ! podman image exists "$JAIL_IMAGE" 2>/dev/null; then
  echo "==> Image $JAIL_IMAGE not found, building it"
  if ! "$WRAPPER_PATH" --update; then
    if ! podman image exists "$JAIL_IMAGE" 2>/dev/null; then
      echo "ERROR: the image $JAIL_IMAGE could not be built." >&2
      exit 1
    fi
    echo "WARNING: the Agency Agents could not be installed." >&2
    echo "         Run 'opencode-jail --agents-update' to retry." >&2
  fi
elif [[ -z "$(ls -A "$AGENTS_DIR" 2>/dev/null)" ]]; then
  echo "==> No agents installed yet, fetching the Agency Agents"
  if ! "$WRAPPER_PATH" --agents-update; then
    echo "WARNING: the Agency Agents could not be installed." >&2
    echo "         Run 'opencode-jail --agents-update' to retry." >&2
  fi
else
  echo "==> Agents already installed ($(find "$AGENTS_DIR" -maxdepth 1 -name '*.md' | wc -l) file(s))"
fi

echo
echo "======================================================================"
echo " OpenCode jail ready"
echo "======================================================================"
echo "  Image    : $JAIL_IMAGE"
echo "  Home     : $JAIL_HOME"
echo "  Config   : $JAIL_HOME/opencode/opencode.json"
echo "  Agents   : $AGENTS_DIR"
echo "  Auth/DB  : $JAIL_HOME/share/"
echo "  FCC env  : $FCC_DIR/.env"
echo "  Launcher : $WRAPPER_PATH"
echo "  Docs     : https://github.com/mbnoimi/OpenCode-Jail"
echo
echo "  Run 'opencode-jail --help' for the launch options."
echo "  Update the image with: opencode-jail --update"
echo "  Update the agents with: opencode-jail --agents-update"
echo "======================================================================"
