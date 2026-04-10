# codexUI — Multi-Profile Fork

This is a personal fork of [codexapp](https://www.npmjs.com/package/codexapp) (originally by Pavel Voronin / Igor Levochkin).

The upstream project exposes the Codex app-server as a single browser-accessible UI. This fork adds **multi-profile, multi-account management** on top of that, with full isolation of each profile's data, auth, and sessions under a dedicated `CODEX_HOME` directory.

---

## What Is Different From Upstream

| Concern | Upstream | This Fork |
|---|---|---|
| Auth | Single account via `codex login` | Multiple accounts, each with its own `auth.json` source |
| Data isolation | `~/.codex` shared by all | Per-profile `CODEX_HOME` under `~/.codex-auth-launcher/profiles/` |
| Session storage | Single namespace | Profile-scoped: sessions, accounts, global state all under CODEX_HOME |
| Running instances | One process | One process per profile, each on its own port |
| Startup management | `npx codexapp` | `codex-web-auth start-folder` or systemd user service |

---

## Directory Layout

```text
~/.codex-auth-launcher/
├── profiles/
│   ├── <profile-name>/
│   │   ├── profile.json          # Profile config
│   │   └── codex-home/           # Isolated CODEX_HOME for this profile
│   │       ├── auth.json         # Symlink → authSource
│   │       ├── sessions/         # Session files (YYYY/MM/DD/)
│   │       ├── session_index.jsonl
│   │       ├── accounts/
│   │       └── .codex-global-state.json
│   └── ...
└── services/                     # PID / log / meta files (managed automatically)
```

### profile.json

```json
{
  "profileName": "example",
  "codexHome": "/home/user/.codex-auth-launcher/profiles/example/codex-home",
  "authSource": "/path/to/actual/auth.json",
  "authLink": "/home/user/.codex-auth-launcher/profiles/example/codex-home/auth.json",
  "baseHome": null,
  "bootstrapHome": "/home/user/.codex",
  "bootstrappedOnFirstUse": false,
  "sharedPaths": []
}
```

`authSource` can be a file or a directory containing `auth.json`. On start, `sync-auth.sh` creates `authLink` as a symlink pointing to the resolved source file.

---

## Installation

**Step 1 — Build and install `codexui` globally:**

```bash
git clone <this-repo>
cd codexUI
pnpm install
pnpm run build
npm install -g .
```

**Step 2 — Install the `codex-web-auth` management command:**

```bash
bash scripts/auth-launcher/install.sh
```

This installs:
- `~/.local/bin/codex-web-auth` — CLI entry point
- `~/.config/systemd/user/codex-web-auth.service` — systemd user service (enabled, not started)

Make sure `~/.local/bin` is on your `PATH`.

---

## Creating a Profile

Create the directory structure manually:

```bash
mkdir -p ~/.codex-auth-launcher/profiles/myprofile/codex-home

cat > ~/.codex-auth-launcher/profiles/myprofile/profile.json <<'EOF'
{
  "profileName": "myprofile",
  "codexHome": "/home/user/.codex-auth-launcher/profiles/myprofile/codex-home",
  "authSource": "/path/to/auth.json",
  "authLink": "/home/user/.codex-auth-launcher/profiles/myprofile/codex-home/auth.json",
  "baseHome": null,
  "bootstrapHome": "/home/user/.codex",
  "bootstrappedOnFirstUse": false,
  "sharedPaths": []
}
EOF
```

---

## Usage

### Start / stop individual profile

```bash
codex-web-auth start   myprofile --port 8051
codex-web-auth stop    myprofile
codex-web-auth restart myprofile
```

### Start / stop all profiles in a folder

```bash
# Start all profiles under ~/.codex-auth-launcher/profiles (ports assigned from 8051)
codex-web-auth start-folder

# With explicit folder and port start
codex-web-auth start-folder ~/.codex-auth-launcher/profiles --port-start 8060

# Stop / restart all
codex-web-auth stop-folder
codex-web-auth restart-folder
```

### Status and logs

```bash
codex-web-auth status
codex-web-auth status-folder
codex-web-auth logs myprofile
codex-web-auth logs myprofile 100
```

### Auth sync

Recreates `auth.json` symlink from `authSource`. Runs automatically on start.

```bash
codex-web-auth sync myprofile
codex-web-auth sync-folder
```

### systemd (auto-start on login)

```bash
systemctl --user start   codex-web-auth   # start all profiles now
systemctl --user stop    codex-web-auth
systemctl --user status  codex-web-auth
journalctl --user -u codex-web-auth -f    # follow logs
```

The install script enables the unit automatically. To enable manually:

```bash
systemctl --user enable codex-web-auth
```

---

## Updating

After pulling changes and rebuilding:

```bash
git pull
pnpm install
pnpm run build
npm install -g .
codex-web-auth restart-folder
```

---

## Architecture

```text
~/.codex-auth-launcher/profiles/
  profile-a/           profile-b/           profile-c/
  └─ codex-home/       └─ codex-home/       └─ codex-home/
       CODEX_HOME=↑         CODEX_HOME=↑         CODEX_HOME=↑
           │                    │                    │
      codexui :8051        codexui :8052        codexui :8053
           │                    │                    │
     Browser tab          Browser tab          Browser tab
```

Each `codexui` process is started with `CODEX_HOME` set to that profile's directory. Sessions, accounts, and global state are fully isolated. The UI reads `CODEX_HOME` for all data operations and the OS user home only for file-browser navigation.

---

## Requirements

- Node.js 18+
- Python 3 (for `profile.json` parsing in shell scripts)
- `pnpm`
- systemd user session (for the service unit; optional)

---

## Upstream

Forked from [codexapp](https://www.npmjs.com/package/codexapp) by Pavel Voronin / Igor Levochkin.
Original source: [friuns2/codexui](https://github.com/friuns2/codexui)
