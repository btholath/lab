#!/usr/bin/env bash
# Installs kubectl and kind into ~/.local/bin (no sudo). Idempotent.
set -euo pipefail
KIND_VERSION="${KIND_VERSION:-v0.27.0}"
BIN="$HOME/.local/bin"; mkdir -p "$BIN"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
esac

if ! command -v kubectl >/dev/null; then
  echo "==> kubectl"
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o "$BIN/kubectl" "https://dl.k8s.io/release/${ver}/bin/linux/${ARCH}/kubectl"
  chmod +x "$BIN/kubectl"
fi

if ! command -v kind >/dev/null; then
  echo "==> kind ${KIND_VERSION}"
  curl -fsSL -o "$BIN/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  chmod +x "$BIN/kind"
fi

case ":$PATH:" in *":$BIN:"*) ;; *)
  grep -q '.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  echo "Added $BIN to PATH in ~/.bashrc. Run: source ~/.bashrc" ;;
esac

kubectl version --client
kind version
docker info >/dev/null 2>&1 || echo "WARNING: Docker is not reachable; kind needs it. Run 'make setup' for guidance."
