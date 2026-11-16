# AGENTS.md — working on this repository

Read this before changing anything. The rules are not stylistic: they protect
the machine the script runs on and the isolation guarantees it claims.
This file is the contract; `README.md` is the short user-facing readme.

Repo: `opencode-jail-installer.sh` (installer) plus the launcher it writes.
Published at <https://github.com/mbnoimi/OpenCode-Jail>. `main` is the only
branch and holds the Podman architecture; the old Landlock/Landstrip version
is gone — do not bring it back.

## The split

| Command | Role |
|---------|------|
| `curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh \| bash` | **installs**, takes no argument: checks Podman + git, writes the state, writes the Containerfile, writes the launcher, builds the image if missing, fetches the agents if missing. Any argument → `ERROR:`. |
| `opencode-jail` | **operates**: every flag lives here. |

Host dependencies: **Podman** and **git**. No host OpenCode, no npm package,
no system packages, no sudo.

## The contract

What the code does. When the code changes, this changes with it.

### Isolation

| Mechanism | What it stops |
|-----------|---------------|
| Image | OpenCode and the tools it drives run inside the container, never on the host |
| Mount namespace | Only the paths of the mount table exist inside; the rest of the host does not exist at all |
| Launcher guards | The workspace is pinned, `/` and `$HOME` (and its parents) are refused, a missing image is a hard error |

No second, OpenCode-level permission layer: the seeded configuration holds
only the plugin list and the compaction switch. The container is the boundary.

### Mount table

| Host path | Inside the container | Mode |
|-----------|----------------------|------|
| the workspace | `/workspace` | read/write |
| `~/.config/opencode-jail/opencode` | `/home/node/.config/opencode` | read/write |
| `~/.config/opencode-jail/share` | `/home/node/.local/share/opencode` | read/write |
| `~/.config/opencode-jail/state` | `/home/node/.local/state/opencode` | read/write |
| `~/.config/opencode-jail/cache` | `/home/node/.cache/opencode` | read/write |
| `~/.config/opencode-jail/npm` | `/home/node/.npm` | read/write |
| `~/.config/opencode-jail/playwright` | `/home/node/.cache/ms-playwright` | read/write |
| `~/.config/opencode-jail/fcc` | `/home/node/.fcc` | read/write |
| `~/.config/opencode-jail/gitconfig` | `/home/node/.gitconfig` | read-only |

### Guards

- The workspace is the only mounted project directory and the only one the
  agent may write to for its own work.
- `/`, `$HOME` and every parent of `$HOME` are refused; everything else is
  accepted, inside `$HOME` and outside it.
- A missing image is a hard error for the launch, `--fcc-admin`,
  `--fcc-restart` and the model refresh. Only `--update` builds it.
- The launcher forwards nothing to OpenCode — every argument it parses is
  consumed, so the container always starts the interactive TUI.

### Files

| Path | Purpose |
|------|---------|
| `~/.local/bin/opencode-jail` | the launcher — generated, never edited by hand |
| `~/.config/opencode-jail/Containerfile` | the image definition, read back by `--update` |
| `~/.config/opencode-jail/opencode/opencode.json` | global config — seeded from the image on the first launch |
| `~/.config/opencode-jail/opencode/agents/*.md` | the Agency Agents |
| `~/.config/opencode-jail/agency-agents/` | shallow checkout of the Agency Agents repository |
| `~/.config/opencode-jail/share/` | sessions, storage, the OpenCode credentials (`auth.json`) |
| `~/.config/opencode-jail/state/` | OpenCode runtime state |
| `~/.config/opencode-jail/cache/` | OpenCode cache and the plugin packages |
| `~/.config/opencode-jail/npm/` | npm cache of the container |
| `~/.config/opencode-jail/playwright/` | Playwright browsers |
| `~/.config/opencode-jail/fcc/.env` | Free Claude Code config (`FCC_OPEN_BROWSER=false`) |
| `~/.config/opencode-jail/fcc/fcc-models.txt` | models that answered the last random test |
| `~/.config/opencode-jail/fcc/fcc-all-models.txt` | models that answered the last full test |
| `~/.config/opencode-jail/fcc/.refresh-models.sh` | the model test — it runs inside the image |
| `~/.config/opencode-jail/gitconfig` | git identity, mounted read-only |

Nothing else on the host is touched: no `~/.config/opencode`, no `~/.bashrc`,
no system packages.

There is **no uninstaller**: the removal is manual and documented in the
README (*Uninstall*) — the launcher `~/.local/bin/opencode-jail`, the state
`~/.config/opencode-jail`, the image `opencode-jail:latest` and the
container `opencode-jail-fcc-admin`. The jail creates no named volume; every
mount is a bind mount of a directory in the state.

### Image

`FROM node:22-bookworm`, `node` remapped to the host UID/GID (`HOST_UID` /
`HOST_GID` build args). Ships `ca-certificates`, `curl`, `git`, `jq`,
`python3`, `unzip`, `findutils`; OpenCode 2 (`https://opencode.ai/v2/install`,
`OPENCODE_DISABLE_AUTOUPDATE=1`); `uv` (`https://astral.sh/uv/install.sh`)
and Free Claude Code (`uv tool install free-claude-code`).

Seed `/opt/opencode-jail/seed/opencode.json`:
`{"plugins":["@cortexkit/opencode-magic-context@latest"],"compaction":{"auto":false}}`
— the plugin list, and OpenCode's own compaction off so Magic Context owns the
context.

Entrypoint `/opt/opencode-jail/init.sh`: ensures the config directory
exists, copies the seed when there is none, starts `fcc-server` when
`JAIL_START_FCC_SERVER=1` and nothing answers on port 8082 yet, then execs
`${OPENCODE_BIN}`. The Agency Agents are **not** in the image.

### Flags

| Flag | Effect |
|------|--------|
| `--update` | rebuild the image (OpenCode, FCC) and refresh the Agency Agents |
| `--agents-update` | refresh the Agency Agents only |
| `--fcc-refresh-models` | test `FCC_MODEL_COUNT` (50) random proxy models, keep the working ones in `fcc-models.txt`, rewrite `MODEL_FALLBACKS` in `fcc/.env` |
| `--fcc-refresh-all-models` | the same, with every model the proxy advertises (`fcc-all-models.txt`) |
| `--fcc` | launch through Free Claude Code, starting `fcc-server` when nothing answers on port 8082 yet |
| `--fcc-admin` | make sure `fcc-server` runs in the container `opencode-jail-fcc-admin`, open the admin UI |
| `--fcc-restart` | recreate that container so it picks up the config saved in the admin UI |
| `-w`, `--workspace <dir>` | project directory — same as the positional argument |
| `-h`, `--help` | usage |

Knobs at the top of the launcher: `OPENCODE_JAIL_IMAGE` (`opencode-jail:latest`),
`FCC_MODEL_COUNT` (50), `FCC_REQUEST_TIMEOUT` (45), `FCC_MAX_FALLBACKS` (120),
`FCC_BASE_URL` (`http://127.0.0.1:8082`).

### Honest limits

- The jail state is reachable and writable from inside — the agent's `bash`
  can read `auth.json`, the seeded config and the FCC config. OpenCode has
  to write there (sessions, caches, plugins). Keep your provider keys out
  of the global config and rotate what the container can reach.
- The network is not isolated: `--network=host` shares the host's network
  namespace, so the container reaches the proxy on `127.0.0.1:8082` and every
  other service the host listens on. Deliberate — the proxy must be
  reachable.
- The workspace is fully writable by the agent, by design.
- `~/.gitconfig` is readable (usually a name and an e-mail) and read-only
  inside.
- The image is an artifact you trust; the build downloads its content.
- Your host OpenCode is never used — the jail runs the one from the image.
- The UID/GID is baked into the image: after a UID change, `opencode-jail --update`.
- The launcher needs a terminal (`-it`). Headless:
  `script -qec 'opencode-jail <path>' /dev/null`.
- `--fcc-restart` stops a running jail session on purpose: a session with its
  own `fcc-server` would keep the old configuration alive.

## Testing rules (mandatory)

1. **Never execute `opencode-jail-installer.sh`** — not locally, not over
   SSH, not via `nohup`, not through a subagent, not with
   `bash opencode-jail-installer.sh`. Same for everything it does on the
   host: the launcher it writes, `podman build` / `podman run` of the jail
   image, any write into `~/.config/opencode-jail/`. **The user runs it by
   hand after each change** and reports what happened.
2. **Static checks only:** `bash -n opencode-jail-installer.sh` (parse only),
   `shellcheck opencode-jail-installer.sh` when installed, and reading the
   generated `Containerfile` and launcher (both heredocs in the script)
   against the tables above. Extracting a heredoc to a file and running
   `bash -n` on it is fine — do not run it.
3. **No verification by proxy:** no simulated `podman` commands, no package
   installs, no containers started from the jail image. Behaviour that was
   not observed is not verified.
4. **Report what the user has to run:** the exact commands and what a good
   result looks like.
5. **Never hardcode credentials** in the script, the docs or a commit.

## Invariants that must not regress

- **Fail closed.** Missing Podman, missing git, missing image or empty agent
  install → `ERROR:` and a non-zero exit. No host-side fallback, no "run it
  without the container" path.
- **The container denies the whole host filesystem** — only the mount table
  exists inside; `~/.ssh`, `~/.aws`, `~/.gnupg`, `/root` and every other
  project cannot be read, written or listed.
- **The jail state is reachable by design** (read/write) — a real limit, not a
  bug; the README must keep saying so.
- **`~/.gitconfig` is read-only** — the identity is readable, not rewritable.
- **`--network=host` is on purpose** — the FCC proxy listens on
  `127.0.0.1:8082` of the host and the container must reach it. The
  consequence is documented, not hidden.
- **The config key set must fit OpenCode 2** — its schema is strict, one
  unknown key refuses the whole file. Only `plugins` and `compaction.auto`.
- **Magic Context needs `compaction.auto = false`** — do not remove it.
- **No Landstrip/Landlock/Sandbox architecture** — no `opencode-landstrip`
  plugin, no `~/.config/opencode/sandbox.json`, no
  `@data-fair/tool-ai-sandbox`, no `ghcr.io/data-fair/tool-ai-sandbox` image.
  Do not reintroduce or document them.
- **The UID/GID is baked into the image** — after a UID change, rebuild with
  `opencode-jail --update`.
- **The Agency Agents are not in the image** — host clone, convert, mount.
  An embedded copy cannot be refreshed without a rebuild.
- **The agent install must not be empty** — `--agents-update` fails when the
  conversion produces no agent file.
- **A restart must never report a false success** — `--fcc-restart` proves
  a new instance id took the port and errors out when it did not. Same for
  every step that claims something is running.
- **Provenance is explicit** — the build pulls `node:22-bookworm`,
  `https://opencode.ai/v2/install`, `https://astral.sh/uv/install.sh` and
  `free-claude-code` from PyPI; the host pulls
  `msitarzewski/agency-agents` from GitHub; the installer itself is
  distributed from
  `https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh`.
  No new source without a line in the tech stack.
- **No secrets in the repository** — no passwords, tokens or private keys in
  code, comments, logs or docs.

## Implementation rules

- **The installer must stay pipe-safe** — it is published as
  `curl -fsSL … | bash`: it never reads stdin, never uses `$0`, and every
  child that could prompt gets an explicit `</dev/null`. The canonical URL
  is `https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh`.
- Bash only, `set -euo pipefail`, no unbound variables, no reliance on the
  caller's `PATH` beyond the documented ones.
- **The installer must not modify the host** — no `sudo`, no `apt`, no
  `npm`/`pip`, no writes outside `~/.config/opencode-jail/` and
  `~/.local/bin/opencode-jail`. The host's own `~/.config/opencode` is none
  of our business.
- **Host dependencies are Podman and git** — `jq`, `node`, `npm`, `python`
  and `curl` live in the image; work that needs them (the FCC model test)
  runs inside the jail image with the state directory mounted.
- **Never swallow a command that starts something** — `podman run`,
  `podman build` and `git clone` either succeed visibly or abort with an
  `ERROR:` line, never fail silently and leave an old process serving.
- Every step prints a `==>` line; every failure prints `ERROR:` to stderr
  and exits non-zero.
- **Idempotent** — running the installer twice converges on the same state,
  a failed run leaves no half-written config and no stale launcher behind.
  Write through a temporary file plus `mv` so a failure cannot truncate.
- The image definition and the launcher are heredocs in the installer, kept
  in sync with the mount table above. The definition is written to
  `~/.config/opencode-jail/Containerfile` and read back by `--update`, so
  there is exactly one copy of it.
- **The operational logic lives in the launcher** (build, agents, model
  test). The installer must not duplicate it — it calls the launcher it has
  just written.
- Prefer `jq` for JSON inside the image; the installer writes the seeded
  JSON with `printf`, so the host needs no `jq`.
- **Do not silently change the security posture** — a changed mount, flag or
  default goes into this file, into the README and into the summary the
  script prints.

## Documentation rules

- **This file is the contract** — architecture, mount table, flags, limits,
  invariants. Every change to behaviour, flags, files, defaults or the
  isolation model lands here in the same change.
- **`README.md` is the short user readme** — what it is, install, use, what
  the agent sees, limits, troubleshooting, tech stack. Keep it short; do not
  grow it into a copy of this file.
- The README must never describe behaviour the script does not implement.
- The last section of the README is the **tech stack** with links — add a
  link for every new tool, package, service or upstream project, keep them
  alive.
- Document the honest limits: the reachable jail state, the shared network,
  the read-only `gitconfig`, the writable workspace, the image you trust.

## Workflow

1. Read `README.md` and this file.
2. Change `opencode-jail-installer.sh`.
3. `bash -n opencode-jail-installer.sh` (parse only, nothing is executed).
4. Update this file (contract) and the README (behaviour, tech stack).
5. Tell the user the exact command to run and what to check — the user runs
   it, the agent never does.
