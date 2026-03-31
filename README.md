# dploy

Simple CLI to deploy frontend builds to remote servers via SSH.

No CI/CD setup needed — just run `dploy` from your project folder.

## Install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/ganiyevuz/dploy/main/install.sh | bash
```

**Homebrew:**

```bash
brew tap ganiyevuz/dploy https://github.com/ganiyevuz/dploy
brew install dploy
```

**Scoop (Windows — requires Git Bash or WSL):**

```powershell
scoop bucket add ganiyevuz https://github.com/ganiyevuz/dploy
scoop install dploy
```

**Manual:**

```bash
git clone https://github.com/ganiyevuz/dploy.git
cd dploy
./dploy.sh install
```

## Quick Start

```bash
cd your-frontend-project

# Create config
dploy init

# Edit .env with your server details
vim .env

# Deploy
dploy
```

## Configuration

`dploy` reads a `.env` file from the current directory:

```env
SERVER=root@your-server-ip
DEPLOY_DIR=/var/www/myapp/frontend
# SSH_KEY=~/.ssh/id_rsa
# BUILD_CMD=npm run build
```

| Variable | Required | Description |
|----------|----------|-------------|
| `SERVER` | Yes | SSH target (e.g. `root@192.168.1.10`) |
| `DEPLOY_DIR` | Yes | Absolute path on server |
| `SSH_KEY` | No | Path to SSH private key (auto-detects `id_ed25519` or `id_rsa`) |
| `BUILD_CMD` | No | Build command (default: `npm run build`) |

> **Note:** dploy uses SSH key authentication only — no passwords. Make sure your public key is on the server (`ssh-copy-id root@server`).

## Commands

| Command | Description |
|---------|-------------|
| `dploy` | Detect build folder, confirm, deploy |
| `dploy build` | Run build command, then deploy |
| `dploy rollback` | Restore previous version on server |
| `dploy status` | Check current deployment info |
| `dploy init` | Create `.env` template |
| `dploy install` | Install globally to `/usr/local/bin` |

## Flags

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Skip confirmation prompts (for CI) |
| `-v`, `--version` | Show version |
| `-h`, `--help` | Show help |

## How It Works

1. Reads `SERVER`, `SSH_KEY`, and `DEPLOY_DIR` from `.env`
2. Auto-detects build folder (`dist/`, `build/`, `out/`, `.next/`)
3. Shows deploy summary and asks for confirmation
4. Archives the build folder and uploads via SCP
5. Backs up current version on server (keeps last 3)
6. Extracts new files

```
┌─────────────┐      SCP       ┌─────────────────┐
│  Local       │ ──────────── > │  Server          │
│  dist/       │    tar.gz      │  /var/www/app/   │
│  build/      │                │  _backup_*       │
└─────────────┘                └─────────────────┘
```

## Examples

```bash
# Standard deploy
dploy

# Build and deploy in one step
dploy build

# Deploy without confirmation (CI/CD)
dploy -y

# Build and deploy without confirmation
dploy build -y

# Something went wrong? Rollback
dploy rollback

# Check what's deployed
dploy status
```

## Requirements

- `bash` 4+
- `ssh` / `scp`
- `tar`

## License

MIT
