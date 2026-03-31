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

# Create config files (.env, .env.example, .dployignore)
dploy init

# Edit .env with your server details
vim .env

# Verify everything works
dploy doctor

# Deploy
dploy
```

## Configuration

### .env

`dploy` reads a `.env` file from the current directory:

```env
SERVER=root@your-server-ip
DEPLOY_DIR=/var/www/myapp/frontend
# SSH_KEY=~/.ssh/id_rsa
# SSH_PORT=22
# BUILD_CMD=npm run build
# POST_DEPLOY_CMD=systemctl reload nginx
```

| Variable | Required | Description |
|----------|----------|-------------|
| `SERVER` | Yes | SSH target (e.g. `root@192.168.1.10`) |
| `DEPLOY_DIR` | Yes | Absolute path on server |
| `SSH_KEY` | No | Path to SSH private key (auto-detects `id_ed25519` or `id_rsa`) |
| `SSH_PORT` | No | SSH port (default: `22`) |
| `BUILD_CMD` | No | Build command (default: `npm run build`) |
| `POST_DEPLOY_CMD` | No | Command to run on server after deploy (e.g. `systemctl reload nginx`) |

> **Note:** dploy uses SSH key authentication only — no passwords. Make sure your public key is on the server (`ssh-copy-id root@server`).

### .env.example

`dploy init` also creates `.env.example` — a safe-to-commit template so teammates know the config format:

```bash
# Share with your team
git add .env.example .dployignore
```

### .dployignore

Exclude files from deployment (created by `dploy init`):

```gitignore
# Source maps
*.map

# Dev/test files
*.test.*
*.spec.*
__tests__
```

Uses tar `--exclude` glob patterns — same syntax as `.gitignore`.

## Commands

| Command | Description |
|---------|-------------|
| `dploy` | Detect build folder, confirm, deploy |
| `dploy build` | Run build command, then deploy |
| `dploy rollback` | Pick and restore a backup version |
| `dploy logs` | Show deploy history and backups |
| `dploy ssh` | SSH into the server |
| `dploy status` | Check current deployment info |
| `dploy doctor` | Run all checks (SSH, permissions, disk, config) |
| `dploy update` | Update dploy to latest version |
| `dploy init` | Create `.env`, `.env.example`, `.dployignore` |
| `dploy install` | Install globally to `/usr/local/bin` |
| `dploy uninstall` | Remove dploy from system |

## Flags

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Skip confirmation prompts (for CI) |
| `-v`, `--version` | Show version |
| `-h`, `--help` | Show help |

## Doctor

Run `dploy doctor` to check your setup before deploying:

```
$ dploy doctor
dploy doctor v1.2.0

✓ .env file found
✓ SSH key found: id_ed25519
✓ SSH key permissions OK (600)
✓ SSH connection to 192.168.1.10:22
⚠ Deploying as root — consider a deploy user
✓ Write permission to /var/www/app
✓ DEPLOY_DIR path is safe: /var/www/app
✓ Disk space OK: 45% used (12G free)
✓ .dployignore found (4 rules)
✓ Build folder detected: dist/ (142 files)

✓ 9 passed, 1 warnings
```

**Checks performed:**
- `.env` exists and has required fields
- SSH key exists with correct permissions (600)
- SSH connection works
- Root user warning
- Write permissions on deploy path
- Dangerous system paths warning
- Disk space (warns >80%, fails >90%)
- `.dployignore` present
- Post-deploy command exists on server
- Build folder detected locally

## Security

dploy warns but doesn't block when using `root`. For production, we recommend:

```bash
# On your server: create a deploy user
adduser deploy
mkdir -p /var/www/myapp
chown deploy:deploy /var/www/myapp

# If POST_DEPLOY_CMD needs sudo (e.g. nginx reload):
echo 'deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx' | sudo tee /etc/sudoers.d/dploy

# Copy your SSH key
ssh-copy-id deploy@your-server

# Update .env
SERVER=deploy@your-server
```

## How It Works

1. Reads `SERVER`, `SSH_KEY`, and `DEPLOY_DIR` from `.env`
2. Auto-detects build folder (`dist/`, `build/`, `out/`, `.next/`)
3. Checks security (root warning, path validation)
4. Applies `.dployignore` exclusions
5. Shows deploy summary and asks for confirmation
6. Verifies SSH connection and write permissions
7. Archives the build folder and uploads via SCP
8. Backs up current version on server (keeps last 3)
9. Extracts new files
10. Runs `POST_DEPLOY_CMD` if configured
11. Shows per-step and total deploy time

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

# Something went wrong? Pick a backup to rollback
dploy rollback
# Output:
#   [1] 2026-03-31 14:20:15  (142 files, 2.1M)  ← latest
#   [2] 2026-03-31 12:05:33  (138 files, 2.0M)
#   [3] 2026-03-30 18:44:02  (135 files, 1.9M)
#   Select backup [1-3] (default: 1):

# Check what's deployed
dploy status

# View deploy history
dploy logs

# Verify setup
dploy doctor

# Quick SSH access
dploy ssh

# Update dploy itself
dploy update
```

## Requirements

- `bash` 4+
- `ssh` / `scp`
- `tar`
- `curl` (for updates)

## License

MIT
