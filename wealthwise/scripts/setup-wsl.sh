#!/usr/bin/env bash
# One-shot, idempotent prerequisites for Ubuntu on WSL2. Safe to re-run.
set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "Base packages"
sudo apt-get update -y
sudo apt-get install -y curl jq make git ca-certificates unzip

say ".NET 10 SDK"
if dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
  echo "already installed"
else
  sudo apt-get install -y dotnet-sdk-10.0 || {
    echo "apt package not available, falling back to Microsoft's install script"
    curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$HOME/.dotnet"
    grep -q 'DOTNET_ROOT' "$HOME/.bashrc" || {
      echo 'export DOTNET_ROOT="$HOME/.dotnet"; export PATH="$PATH:$DOTNET_ROOT"' >> "$HOME/.bashrc"
    }
    echo "Open a new shell (or: source ~/.bashrc) so 'dotnet' is on PATH."
  }
fi

say "Node 22 (via nvm)"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install 22 >/dev/null && nvm alias default 22 >/dev/null
node -v

say "Docker"
if have docker && docker info >/dev/null 2>&1; then
  docker --version
  docker compose version
else
  cat <<'MSG'
Docker is not reachable from this WSL distro. Pick ONE:
  A) Docker Desktop on Windows -> Settings -> Resources -> WSL integration -> enable for this distro.
  B) Native engine inside WSL:
       curl -fsSL https://get.docker.com | sudo sh
       sudo usermod -aG docker "$USER"   # then: wsl --shutdown, reopen the terminal
       (needs systemd: /etc/wsl.conf -> [boot] systemd=true)
Then re-run: make setup
MSG
fi

say "Optional: nektos/act to run GitHub Actions locally"
have act && echo "act present" || echo "install later with: curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash"

say "Done. Next: make up"
