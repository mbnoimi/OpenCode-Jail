#!/usr/bin/env bash
# The installer needs bash. The check comes before "set" so that a
# "curl ... | sh" gets this message instead of a parse error.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: this uninstaller needs bash." >&2
  echo "       Run it with: bash opencode-jail-uninstaller.sh" >&2
  exit 1
fi
set -euo pipefail

# opencode-jail-uninstaller.sh — uninstall the OpenCode 2 jail from this machine.
#
#   curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-uninstaller.sh | bash
#
# The uninstaller takes no positional argument. It:
#   - checks that Podman is available,
#   - stops and removes the managed fcc-server container (opencode-jail-fcc-admin),
#   - stops and removes any running jail sessions,
#   - removes the jail image (opencode-jail:latest),
#   - removes the launcher (~/.local/bin/opencode-jail),
#   - with --delete-data: also removes the jail state (~/.config/opencode-jail).
#
# Options:
#   --delete-data    Also remove ~/.config/opencode-jail (sessions, credentials, agents, FCC config)
#   --dry-run        Show what would be done without executing
#   -h, --help       Show this help
#
# The script never reads stdin, so it can be piped from curl.

JAIL_IMAGE="${OPENCODE_JAIL_IMAGE:-opencode-jail:latest}"
ADMIN_CONTAINER="opencode-jail-fcc-admin"
WRAPPER_PATH="$HOME/.local/bin/opencode-jail"
JAIL_HOME="$HOME/.config/opencode-jail"

DELETE_DATA=0
DRY_RUN=0

usage() {
  cat <<EOF
opencode-jail-uninstaller.sh — uninstall the OpenCode 2 jail

Usage:
  curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-uninstaller.sh | bash
  curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-uninstaller.sh | bash -s -- --delete-data
  curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-uninstaller.sh | bash -s -- --dry-run
  bash opencode-jail-uninstaller.sh [--delete-data] [--dry-run]

Options:
  --delete-data    Also remove the jail state directory (~/.config/opencode-jail)
                   This deletes your sessions, credentials, agents and FCC config.
  --dry-run        Show what would be done without executing.
  -h, --help       Show this help.

The uninstaller takes no positional argument.

What is removed by default:
  - Container: $ADMIN_CONTAINER (managed fcc-server)
  - Containers: any running opencode-jail sessions (ancestor of $JAIL_IMAGE)
  - Image:     $JAIL_IMAGE
  - Launcher:  $WRAPPER_PATH

What is removed with --delete-data:
  - State dir: $JAIL_HOME (sessions, auth.json, agents, FCC config, caches)

EOF
  exit "${1:-0}"
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage 0 ;;
    --delete-data) DELETE_DATA=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage 1 ;;
  esac
fi

if [[ $# -gt 0 ]]; then
  echo "ERROR: unexpected argument: $1" >&2
  usage 1
fi

command -v podman >/dev/null 2>&1 || {
  echo "ERROR: Podman is required. Install it first." >&2
  exit 1
}

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

echo "==> OpenCode Jail Uninstaller"
[[ $DRY_RUN -eq 1 ]] && echo "    (dry-run mode — no changes will be made)"

# 1. Stop and remove the managed fcc-server container
if podman container exists "$ADMIN_CONTAINER" >/dev/null 2>&1; then
  echo "==> Stopping and removing container: $ADMIN_CONTAINER"
  run "podman stop -t 5 '$ADMIN_CONTAINER' >/dev/null 2>&1 || true"
  run "podman rm -f '$ADMIN_CONTAINER' >/dev/null 2>&1 || true"
else
  echo "==> Container $ADMIN_CONTAINER not found"
fi

# 2. Stop and remove any running jail sessions (containers from the jail image)
echo "==> Checking for running jail sessions..."
session_ids=()
while IFS= read -r id; do
  [[ -n "$id" ]] && session_ids+=("$id")
done < <(podman ps --filter "ancestor=$JAIL_IMAGE" --format '{{.ID}}' 2>/dev/null)

if [[ ${#session_ids[@]} -gt 0 ]]; then
  echo "    Found ${#session_ids[@]} running session(s)"
  for id in "${session_ids[@]}"; do
    name="$(podman inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||')"
    echo "==> Stopping and removing jail session: $name ($id)"
    run "podman stop -t 5 '$id' >/dev/null 2>&1 || true"
    run "podman rm -f '$id' >/dev/null 2>&1 || true"
  done
else
  echo "    No running jail sessions found"
fi

# 3. Remove the jail image
if podman image exists "$JAIL_IMAGE" >/dev/null 2>&1; then
  echo "==> Removing image: $JAIL_IMAGE"
  run "podman rmi '$JAIL_IMAGE'"
else
  echo "==> Image $JAIL_IMAGE not found"
fi

# 4. Remove the launcher
if [[ -f "$WRAPPER_PATH" ]]; then
  echo "==> Removing launcher: $WRAPPER_PATH"
  run "rm -f '$WRAPPER_PATH'"
else
  echo "==> Launcher $WRAPPER_PATH not found"
fi

# 5. Remove the jail state directory (optional)
if [[ $DELETE_DATA -eq 1 ]]; then
  if [[ -d "$JAIL_HOME" ]]; then
    echo "==> Removing jail state directory: $JAIL_HOME"
    run "rm -rf '$JAIL_HOME'"
  else
    echo "==> Jail state directory $JAIL_HOME not found"
  fi
else
  echo "==> Keeping jail state directory: $JAIL_HOME"
  echo "       (use --delete-data to remove it)"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "Dry run complete. No changes were made."
  echo "Run without --dry-run to execute."
else
  echo
  echo "======================================================================"
  echo " OpenCode Jail uninstalled"
  echo "======================================================================"
  [[ $DELETE_DATA -eq 1 ]] && echo "  State directory removed: $JAIL_HOME" || echo "  State directory kept:    $JAIL_HOME"
  echo "  Image removed:           $JAIL_IMAGE"
  echo "  Launcher removed:        $WRAPPER_PATH"
  echo "  Containers removed:      $ADMIN_CONTAINER + any jail sessions"
  echo
  echo "Optional: clean up unused Podman data (images, containers, networks, build cache):"
  echo "  podman system prune"
  echo "======================================================================"
fi