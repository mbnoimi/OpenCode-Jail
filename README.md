# OpenCode Jail

**OpenCode 2 inside a sandboxed, rootless Podman container.**

The agent gets one project and nothing else. Your SSH keys, your cloud
credentials, your other repositories — they are not in the container. A path
that is not mounted does not exist there; it is not a permission error.

Source: <https://github.com/mbnoimi/OpenCode-Jail>

## Requirements

- Linux with [Podman](https://podman.io/) and `git`:

  ```bash
  sudo apt-get install -y podman git      # Debian / Ubuntu / Mint
  ```

- a subordinate UID/GID range for your user (the container runs with
  `--userns=keep-id`):

  ```bash
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
  # log out and in again
  ```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh | bash
```

That is the whole installation. It puts one command in `~/.local/bin`:

- **`opencode-jail`** — run OpenCode in the sandbox

The first run builds the image (a few minutes: OpenCode 2, `uv`, Free Claude
Code). The installer takes no argument; re-running it refreshes the launcher
and the state, and rebuilds the image only when it is missing.

Prefer to have the sources on disk?

```bash
git clone https://github.com/mbnoimi/OpenCode-Jail.git
cd OpenCode-Jail
bash opencode-jail-installer.sh
```

### Upgrade

```bash
curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-installer.sh | bash
opencode-jail --update
```

The first command updates the launcher, the second rebuilds the image (new
OpenCode, new Free Claude Code) and refreshes the Agency Agents.

## Use

```bash
opencode-jail                  # the current directory
opencode-jail ~/code/my-app    # a project
```

| Option | Effect |
|--------|--------|
| `-w`, `--workspace <dir>` | project directory (also accepted as the only positional argument) |
| `--fcc` | run through the local Free Claude Code proxy |
| `--fcc-admin` | start the proxy and open its admin UI |
| `--fcc-restart` | apply what you saved in the admin UI |
| `--update` | new OpenCode, new Free Claude Code, new agents |
| `--agents-update` | new Agency Agents only |
| `--fcc-refresh-models` | test 50 random models of the proxy, keep the ones that answer |
| `--fcc-refresh-all-models` | the same, with every model the proxy advertises |

## Examples

**A project**

```bash
opencode-jail ~/code/my-app       # a project
opencode-jail -w ~/code/my-app    # the same, explicit
cd ~/code/my-app && opencode-jail # the current directory
```

**One directory of a bigger repository**

```bash
opencode-jail ~/code/repo/services/api
```

Only that directory is inside the container — the rest of the repository is
not.

**A project outside your home directory**

```bash
opencode-jail /opt/myapp
```

`/`, your home directory and its parents are refused, everything else works.

**The free models of the local proxy**

```bash
opencode-jail --fcc-admin          # once: add your provider keys in the UI
opencode-jail --fcc ~/code/my-app  # run through the proxy
opencode-jail --fcc-restart        # after you changed something in the admin UI
```

**A fallback list that actually works**

```bash
opencode-jail --fcc-refresh-models       # 50 random models, quick
opencode-jail --fcc-refresh-all-models   # every model the proxy offers
```

Both test the models against the proxy and rewrite `MODEL_FALLBACKS` in
`~/.config/opencode-jail/fcc/.env` with the ones that answer; the primary
model stays untouched. The proxy has to be running.

**A new OpenCode, new agents**

```bash
opencode-jail --update           # rebuild the image and refresh the agents
opencode-jail --agents-update    # only the agents
```

## What the agent can see

| On your machine | In the container | Access |
|-----------------|------------------|--------|
| the project you picked | `/workspace` | read/write |
| the jail state (config, sessions, credentials, caches, FCC) | `/home/node/.config/opencode`, `…/.local/share/opencode`, … | read/write |
| your `~/.gitconfig` | `/home/node/.gitconfig` | read-only |
| everything else | — | does not exist |

The workspace is the only project directory in the container, and the only
one the agent may write to.

## Good to know

- The jail state is reachable from inside — the agent can read
  `auth.json`, the seeded configuration and the Free Claude Code
  configuration. They have to be writable there, because OpenCode writes
  its sessions and caches.
- The container shares your network (`--network=host`), so it can reach the
  local proxy on `127.0.0.1:8082` — and every other service you run.
- The workspace is fully writable by the agent, by design.
- The image is an artifact you trust, like every other image you run.
- Your host OpenCode is not used at all — the jail runs the one from the
  image.
- The launcher needs a terminal. Headless:
  `script -qec 'opencode-jail ~/code/my-app' /dev/null`.

## Troubleshooting

| Message | Fix |
|---------|-----|
| `ERROR: Podman is required. Install it first.` | install Podman; the installer never installs system packages itself |
| `ERROR: image opencode-jail:latest not built.` | `opencode-jail --update` |
| `the input device is not a TTY` | `script -qec 'opencode-jail <path>' /dev/null` |
| `--userns=keep-id` fails | no subordinate UID range — see the requirements |
| permission errors in the workspace | the image was built for another UID: `opencode-jail --update` |
| no agents installed | `opencode-jail --agents-update` |
| the model refresh finds no models | the proxy must run: `opencode-jail --fcc-admin` |

## Uninstall

The jail registers nothing with your system: no service, no desktop entry.
It is three things — a launcher, a state directory and a container image.

### Automatic uninstall (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-uninstaller.sh | bash
```

This stops/removes the managed `fcc-server` container (`opencode-jail-fcc-admin`),
any running jail sessions, the image (`opencode-jail:latest`), and the launcher
(`~/.local/bin/opencode-jail`). The state directory (`~/.config/opencode-jail`)
is **kept** by default (sessions, credentials, agents, FCC config).

| Option | Effect |
|--------|--------|
| `--delete-data` | Also remove `~/.config/opencode-jail` (sessions, auth.json, agents, FCC config, caches) |
| `--dry-run` | Show what would be done without executing |
| `-h`, `--help` | Show help |

```bash
# Also remove the state directory
curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-uninstaller.sh | bash -s -- --delete-data

# Preview what would happen
curl -fsSL https://raw.githubusercontent.com/mbnoimi/OpenCode-Jail/main/opencode-jail-uninstaller.sh | bash -s -- --dry-run
```

### Manual uninstall

If you prefer the manual steps:

**1. Stop the proxy and drop the containers**

```bash
podman rm -f opencode-jail-fcc-admin                    # the managed proxy container
podman ps -a --filter ancestor=opencode-jail:latest     # a session still running?
podman rm -f <name>                                     # remove it
```

**2. Remove the image**

```bash
podman rmi opencode-jail:latest
```

**3. Remove the launcher and the state**

```bash
rm -f ~/.local/bin/opencode-jail
rm -rf ~/.config/opencode-jail
```

That is everything. `~/.config/opencode-jail` holds the configuration, the
sessions, the OpenCode credentials (`auth.json`), the caches, the Agency
Agents and the Free Claude Code configuration (with the proxy token) — and
the jail mounts directories, it creates no named volume.

If you cloned the repository, the clone itself is not needed either:

```bash
rm -rf ~/code/OpenCode-Jail
```

> Delete the state **last**: it is the only copy of your sessions, your
> credentials and the proxy configuration. There is no backup.

**Optional: clean up what is left**

```bash
podman system prune
```

This removes the unused images, the stopped containers, the unused networks
and the build cache — of the **whole machine**, not only of the jail. Use it
only when you know that nothing else of yours is running. The jail's own
image and container are already gone by then.

If you built the image under a different name (`OPENCODE_JAIL_IMAGE`), use
that name in the commands above.

## Tech stack

- OpenCode — <https://opencode.ai>
  - install script (v2) — <https://opencode.ai/v2/install>
  - configuration schema — <https://opencode.ai/config.json>
  - CLI reference — <https://opencode.ai/docs/cli/>
  - plugins guide — <https://opencode.ai/docs/plugins/>
- Podman — <https://podman.io/> and
  - documentation — <https://docs.podman.io/en/latest/>
  - tutorials (rootless setup) — <https://docs.podman.io/en/latest/Tutorials.html>
  - `podman build` — <https://docs.podman.io/en/latest/markdown/podman-build.1.html>
  - `podman run` (`--userns`, `--network`) — <https://docs.podman.io/en/latest/markdown/podman-run.1.html>
  - Debian/Ubuntu packages — <https://packages.ubuntu.com/podman>
- Docker Hub `node:22-bookworm` — <https://hub.docker.com/_/node>
- Debian bookworm — <https://www.debian.org/>
- Magic Context — <https://github.com/cortexkit/magic-context> and
  <https://www.npmjs.com/package/@cortexkit/opencode-magic-context>
- Free Claude Code (FCC) — <https://github.com/Alishahryar1/free-claude-code>
  and <https://pypi.org/project/free-claude-code/>
- Agency Agents — <https://github.com/msitarzewski/agency-agents>
- uv — <https://github.com/astral-sh/uv> and <https://docs.astral.sh/uv/>
- Python — <https://www.python.org/>
- Git — <https://git-scm.com/> (host requirement, the Agency Agents checkout)
- jq — <https://jqlang.github.io/jq/> (inside the image, for the model test)
- curl — <https://curl.se/>
- ca-certificates — <https://packages.ubuntu.com/ca-certificates>
- GNU findutils — <https://www.gnu.org/software/findutils/>
- Info-ZIP unzip — <https://packages.debian.org/bookworm/unzip> and
  <https://sourceforge.net/projects/infozip/>
- xdg-utils (`xdg-open`) — <https://www.freedesktop.org/wiki/Software/xdg-utils/>
- GNU Bash — <https://www.gnu.org/software/bash/>
- util-linux (`script`) — <https://www.gnu.org/software/coreutils/>
