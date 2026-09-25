#!/bin/bash

# ==========================================
# Automated Installer: Kubeadm 1.35 + Kind + Docker
# OS: Ubuntu 24.04 LTS (WSL2-aware, IDEMPOTENT)
#
# Safe to run any number of times. Each step checks current state first
# and only acts if something is actually missing or misconfigured.
# ==========================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

K8S_MINOR="1.35"
K8S_VERSION_PIN="1.35.6-1.1"   # exact apt version pin; update to match latest 1.35.x patch
KIND_VERSION="v0.26.0"

STEP=0
TOTAL_STEPS=8

step() { STEP=$((STEP+1)); echo -e "\n${BLUE}[STEP ${STEP}/${TOTAL_STEPS}] $1${NC}"; }
ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1 (already satisfied)"; }
doing(){ echo -e "  ${BLUE}[DOING]${NC} $1"; }
fixed(){ echo -e "  ${GREEN}[FIXED]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
pkg_version()   { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo ""; }

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE} Kubernetes ${K8S_MINOR} Stack Installer (idempotent)${NC}"
echo -e "${BLUE}==========================================${NC}"

# ------------------------------------------------------------------
step "Pre-flight checks (systemd, kernel modules, cgroup v2, sysctl)"
# ------------------------------------------------------------------
if [ "$(ps --pid 1 -o comm=)" = "systemd" ]; then
  ok "systemd is PID 1"
else
  fail "systemd is not PID 1. Add '[boot] systemd=true' to /etc/wsl.conf, then 'wsl --shutdown' and retry."
  exit 1
fi

if grep -qw overlay /proc/filesystems; then
  skip "overlay filesystem support already active"
else
  doing "loading overlay module"
  sudo modprobe overlay
  if grep -qw overlay /proc/filesystems; then
    fixed "overlay module loaded"
  else
    fail "overlay support still not active after modprobe"
    exit 1
  fi
fi

if lsmod | grep -q '^br_netfilter'; then
  skip "br_netfilter module already loaded"
else
  doing "loading br_netfilter module"
  sudo modprobe br_netfilter
  fixed "br_netfilter module loaded"
fi

CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup/)
if [ "$CGROUP_TYPE" = "cgroup2fs" ]; then
  ok "cgroup v2 active"
else
  fail "cgroup v2 not active (found: $CGROUP_TYPE). Kubelet/containerd require cgroup v2."
  exit 1
fi

if sudo sysctl net.bridge.bridge-nf-call-iptables >/dev/null 2>&1; then
  ok "bridge netfilter sysctl available"
else
  fail "net.bridge.bridge-nf-call-iptables not available. Run 'wsl --update' from PowerShell and retry."
  exit 1
fi

# ------------------------------------------------------------------
step "System dependencies (apt packages)"
# ------------------------------------------------------------------
REQUIRED_PKGS=(apt-transport-https ca-certificates curl gpg lsb-release software-properties-common)
MISSING_PKGS=()
for p in "${REQUIRED_PKGS[@]}"; do
  if pkg_installed "$p"; then
    : # already installed, will summarize below
  else
    MISSING_PKGS+=("$p")
  fi
done

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
  skip "all base dependencies already installed (${REQUIRED_PKGS[*]})"
else
  doing "installing missing packages: ${MISSING_PKGS[*]}"
  sudo apt-get update
  sudo apt-get install -y "${MISSING_PKGS[@]}"
  fixed "installed: ${MISSING_PKGS[*]}"
fi

# ------------------------------------------------------------------
step "Kernel modules / sysctl persistence + swap"
# ------------------------------------------------------------------
MODULES_CONF=/etc/modules-load.d/k8s.conf
DESIRED_MODULES=$'overlay\nbr_netfilter'
if [ -f "$MODULES_CONF" ] && [ "$(sudo cat "$MODULES_CONF")" = "$DESIRED_MODULES" ]; then
  skip "$MODULES_CONF already correct"
else
  doing "writing $MODULES_CONF"
  echo "$DESIRED_MODULES" | sudo tee "$MODULES_CONF" >/dev/null
  fixed "$MODULES_CONF written"
fi

SYSCTL_CONF=/etc/sysctl.d/k8s.conf
DESIRED_SYSCTL=$'net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward                 = 1'
if [ -f "$SYSCTL_CONF" ] && [ "$(sudo cat "$SYSCTL_CONF")" = "$DESIRED_SYSCTL" ]; then
  skip "$SYSCTL_CONF already correct"
else
  doing "writing $SYSCTL_CONF"
  echo "$DESIRED_SYSCTL" | sudo tee "$SYSCTL_CONF" >/dev/null
  sudo sysctl --system >/dev/null
  fixed "$SYSCTL_CONF written and applied"
fi

if [ -z "$(swapon --show)" ]; then
  skip "swap already off"
else
  doing "disabling swap"
  sudo swapoff -a
  fixed "swap disabled for this session (note: WSL2 may re-enable it after a restart — set swap=0 in .wslconfig on Windows for a permanent fix)"
fi
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab 2>/dev/null || true

# ------------------------------------------------------------------
step "Docker Engine"
# ------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker \
   && docker version --format '{{.Server.Platform.Name}}' 2>/dev/null | grep -qi "Docker Engine"; then
  skip "native Docker Engine already installed and running ($(docker --version))"
else
  doing "installing Docker Engine"
  sudo install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  fi
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  fi
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fixed "Docker Engine installed ($(docker --version))"
fi

if groups "$USER" | grep -qw docker; then
  skip "$USER already in docker group"
else
  doing "adding $USER to docker group"
  sudo usermod -aG docker "$USER"
  fixed "$USER added to docker group (log out/in or 'newgrp docker' to take effect)"
fi

# ------------------------------------------------------------------
step "containerd configuration (systemd cgroups + CRI enabled)"
# ------------------------------------------------------------------
CONTAINERD_CONF=/etc/containerd/config.toml
NEEDS_REGEN=false

if [ ! -f "$CONTAINERD_CONF" ]; then
  NEEDS_REGEN=true
elif sudo grep -q 'disabled_plugins *= *\[.*cri.*\]' "$CONTAINERD_CONF"; then
  warn "CRI plugin is disabled in containerd config"
  NEEDS_REGEN=true
elif ! sudo grep -q 'SystemdCgroup' "$CONTAINERD_CONF"; then
  NEEDS_REGEN=true
fi

if [ "$NEEDS_REGEN" = true ]; then
  doing "regenerating containerd config (backing up existing first)"
  if [ -f "$CONTAINERD_CONF" ]; then
    sudo cp "$CONTAINERD_CONF" "${CONTAINERD_CONF}.bak.$(date +%s)"
  fi
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee "$CONTAINERD_CONF" >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$CONTAINERD_CONF"
  sudo systemctl restart containerd
  fixed "containerd config regenerated with CRI enabled + systemd cgroups"
elif sudo grep -q 'SystemdCgroup = false' "$CONTAINERD_CONF"; then
  doing "flipping SystemdCgroup to true"
  sudo cp "$CONTAINERD_CONF" "${CONTAINERD_CONF}.bak.$(date +%s)"
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$CONTAINERD_CONF"
  sudo systemctl restart containerd
  fixed "SystemdCgroup set to true"
else
  skip "containerd already configured correctly (CRI enabled, systemd cgroups)"
fi

if ! systemctl is-active --quiet containerd; then
  doing "starting containerd"
  sudo systemctl restart containerd
fi

# ------------------------------------------------------------------
step "kubelet, kubeadm, kubectl (pinned to ${K8S_MINOR}.x)"
# ------------------------------------------------------------------
if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
  doing "adding Kubernetes ${K8S_MINOR} apt repository"
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt-get update
  fixed "Kubernetes ${K8S_MINOR} apt repository added"
else
  skip "Kubernetes ${K8S_MINOR} apt repository already configured"
fi

CURRENT_KUBEADM_VER=$(pkg_version kubeadm)
if [ "$CURRENT_KUBEADM_VER" = "$K8S_VERSION_PIN" ] && pkg_installed kubelet && pkg_installed kubectl; then
  skip "kubelet/kubeadm/kubectl already at pinned version ${K8S_VERSION_PIN}"
else
  doing "installing kubelet/kubeadm/kubectl ${K8S_VERSION_PIN}"
  # unhold first in case a previous run held a different version
  sudo apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  if ! sudo apt-get install -y kubelet="${K8S_VERSION_PIN}" kubeadm="${K8S_VERSION_PIN}" kubectl="${K8S_VERSION_PIN}"; then
    warn "exact pin ${K8S_VERSION_PIN} not found in repo; installing latest available ${K8S_MINOR}.x"
    sudo apt-get install -y kubelet kubeadm kubectl
  fi
  fixed "kubelet/kubeadm/kubectl installed"
fi

if apt-mark showhold | grep -qx kubelet && apt-mark showhold | grep -qx kubeadm && apt-mark showhold | grep -qx kubectl; then
  skip "kubelet/kubeadm/kubectl already held"
else
  sudo apt-mark hold kubelet kubeadm kubectl >/dev/null
  fixed "kubelet/kubeadm/kubectl held at current version"
fi

if systemctl is-enabled --quiet kubelet 2>/dev/null; then
  skip "kubelet already enabled"
else
  sudo systemctl enable kubelet >/dev/null 2>&1
  fixed "kubelet enabled"
fi
sudo systemctl start kubelet 2>/dev/null || true   # will crash-loop until kubeadm init; that's expected pre-bootstrap

# ------------------------------------------------------------------
step "Kind (optional lightweight alternative)"
# ------------------------------------------------------------------
CURRENT_KIND_VER=$(kind version 2>/dev/null | awk '{print $2}')
if [ "$CURRENT_KIND_VER" = "$KIND_VERSION" ]; then
  skip "Kind already at ${KIND_VERSION}"
else
  doing "installing Kind ${KIND_VERSION}"
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then
    curl -Lo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  elif [ "$ARCH" = "aarch64" ]; then
    curl -Lo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-arm64"
  else
    fail "unsupported architecture: $ARCH"
    exit 1
  fi
  chmod +x /tmp/kind
  sudo mv /tmp/kind /usr/local/bin/kind
  fixed "Kind ${KIND_VERSION} installed"
fi

# ------------------------------------------------------------------
step "Verification summary"
# ------------------------------------------------------------------
echo "------------------------------------------------"
echo "Docker Version:   $(docker --version 2>/dev/null || echo 'not found')"
echo "Kind Version:     $(kind --version 2>/dev/null || echo 'not found')"
echo "Kubeadm Version:  $(kubeadm version -o short 2>/dev/null || echo 'not found')"
echo "Kubectl Version:  $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion || echo 'not found')"
echo "------------------------------------------------"

echo -e "\n${GREEN}Installation check complete. Safe to re-run this script any time.${NC}"
echo -e "${BLUE}Next: ./bootstrap_cluster.sh for a full kubeadm cluster,${NC}"
echo -e "${BLUE}      OR 'kind create cluster --image kindest/node:v${K8S_MINOR}.0' for Kind.${NC}"
