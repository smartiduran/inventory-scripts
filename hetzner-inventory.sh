#!/usr/bin/env bash
#─────────────────────────────────────────────────────────────────────
# hetzner-inventory.sh
# Inventario automático de servidor Hetzner Cloud (solo lectura).
#
# Salida: YAML a stdout. Redirige a archivo:
#   bash hetzner-inventory.sh > inventory-$(hostname).yaml
#
# Requisitos: bash, jq, curl, lsblk, ip, systemctl, ss, ps, df, dpkg
#            kubectl (si hay Kubernetes), docker (si hay Docker)
# Autor: Ambbit Sentinel  —  repo: smartiduran/inventory-scripts
#─────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Si se ejecuta remotamente vía ssh, no hay archivo local. Ignorar error.
[[ -f "$HERE/hetzner-inventory.sh" ]] || true

# ── helpers ────────────────────────────────────────────────────────
yaml_str() { printf '"%s"\n' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')" ; }
yaml_arr() { # key values...
  local k="$1"; shift
  if [[ $# -eq 0 ]]; then echo "$k: []"; return; fi
  echo "$k:"
  for v in "$@"; do printf '  - '; yaml_str "$v"; done
}
yaml_kv() { # key=value pairs
  local k="$1"; shift
  if [[ $# -eq 0 ]]; then echo "$k: {}"; return; fi
  echo "$k:"
  for p in "$@"; do
    local kk="${p%%=*}" vv="${p#*=}"
    printf '  %s: ' "$kk"; yaml_str "$vv"
  done
}

# ── Sistema ────────────────────────────────────────────────────────
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
DATE=$(date -Iseconds)
OS_PRETTY=$(awk -F= 'BEGIN{ORS=" "} /^PRETTY_NAME/{gsub(/"/,"",$2); print $2}' /etc/os-release)
OS_ID=$(awk -F= '/^ID=/{print $2}' /etc/os-release)
OS_VERSION=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release)
KERNEL=$(uname -r)
ARCH=$(uname -m)
if command -v uptime &>/dev/null; then UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime -p); else UPTIME="unknown"; fi

# ── Hardware ──────────────────────────────────────────────────────
VCPU=$(nproc 2>/dev/null || echo "unknown")
RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
ROOT_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$2); print $2}')
DISK_USE=$(df -h / 2>/dev/null | awk 'NR==2{print $5 " used of " $2}')
DISKS=$(lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk 'NR>1{gsub(/"/,""); print $1 " " $2 " " $3 " " $4}' | tr '\n' ' ')

# ── Red ───────────────────────────────────────────────────────────
PUB_V4=$(curl -s -4 --max-time 4 ifconfig.me 2>/dev/null || echo "unknown")
PUB_V6=$(curl -s -6 --max-time 4 ifconfig.me 2>/dev/null || echo "unknown")
PRIV_IPS=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | grep -v '^127\.' | tr '\n' ' ')
DEF_IF=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
MAC=$(cat "/sys/class/net/${DEF_IF}/address" 2>/dev/null || echo "unknown")

# ── SSH ───────────────────────────────────────────────────────────
SSH_PORT=$(grep -E '^Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
[[ -z "$SSH_PORT" ]] && SSH_PORT="22"
SSH_USERS=$(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd 2>/dev/null | tr '\n' ' ')
AUTH_KEYS=$(find /home -name authorized_keys -type f 2>/dev/null -exec cat {} + | grep -c '^ssh-' || true)
[[ -z "$AUTH_KEYS" ]] && AUTH_KEYS=0
ROOT_LOGIN=$(grep -E '^PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1 || echo "unknown")
PASS_AUTH=$(grep -E '^PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1 || echo "unknown")

# ── Firewall ──────────────────────────────────────────────────────
FW_TOOL="none"
FW_RULES=""
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  FW_TOOL="ufw"
  FW_RULES=$(ufw status numbered 2>/dev/null | sed '1d' | head -20 | tr '\n' ' ')
elif command -v nft &>/dev/null && nft list ruleset &>/dev/null | grep -q table; then
  FW_TOOL="nftables"
  FW_RULES=$(nft list ruleset 2>/dev/null | head -40 | tr '\n' ' ')
elif command -v iptables &>/dev/null && iptables -L -n &>/dev/null | grep -q "^Chain"; then
  FW_TOOL="iptables"
  FW_RULES=$(iptables -L -n 2>/dev/null | head -30 | tr '\n' ' ')
fi

# ── systemd services ──────────────────────────────────────────────
SERVICES=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -v '@' | sort -u | tr '\n' ' ' || echo "")

# ── Docker ────────────────────────────────────────────────────────
DOCKER_RUNNING=false
DOCKER_CONTAINERS=""
CONTAINER_NAMES=""
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  DOCKER_RUNNING=true
  DOCKER_CONTAINERS=$(docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null | tr '\n' ' ')
  CONTAINER_NAMES=$(docker ps --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ' ')
fi

# ── Kubernetes ────────────────────────────────────────────────────
K8S_DISTRO="none"
K8S_VERSION="none"
CNI="none"
CSI="none"
INGRESS="none"
CERT_MANAGER="false"
EXT_DNS="false"
K8S_NODES=""
if command -v kubectl &>/dev/null && kubectl version --client &>/dev/null 2>&1; then
  K8S_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")
  # Distro detect
  if systemctl is-active k3s &>/dev/null 2>&1; then K8S_DISTRO="k3s"
  elif systemctl is-active k0s &>/dev/null 2>&1; then K8S_DISTRO="k0s"
  elif [[ -f /etc/talos/version.yaml ]]; then K8S_DISTRO="talos"
  elif systemctl is-active kubelet &>/dev/null 2>&1 && [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then K8S_DISTRO="kubeadm"
  fi
  # CNI
  if kubectl get pods -A -l k8s-app=cilium -o name &>/dev/null | grep -q .; then CNI="cilium"
  elif kubectl get pods -A -l k8s-app=flannel -o name &>/dev/null | grep -q .; then CNI="flannel"
  elif kubectl get pods -A -l app=calico -o name &>/dev/null | grep -q .; then CNI="calico"
  fi
  # CSI
  if kubectl get storageclass &>/dev/null 2>&1 | grep -q longhorn; then CSI="longhorn"
  elif kubectl get storageclass &>/dev/null 2>&1 | grep -q hcloud; then CSI="hcloud-csi"
  fi
  # Ingress
  if kubectl get pods -A -l app.kubernetes.io/name=traefik &>/dev/null | grep -q .; then INGRESS="traefik"
  elif kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx &>/dev/null | grep -q .; then INGRESS="nginx"
  fi
  # K8s add-ons
  kubectl get pods -A -l app.kubernetes.io/name=cert-manager &>/dev/null | grep -q . && CERT_MANAGER="true"
  kubectl get pods -A -l app.kubernetes.io/name=external-dns &>/dev/null | grep -q . && EXT_DNS="true"
  # Nodos
  K8S_NODES=$(kubectl get nodes -o name 2>/dev/null | awk -F/ '{print $2}' | tr '\n' ' ' || echo "")
fi

# ── Procesos clave ────────────────────────────────────────────────
KEY_PROCS=$(ps aux 2>/dev/null | awk '/[k]ube-apiserver|[k]ube-controller|[k]ube-scheduler|[e]tcd|[c]ilium|[t]raefik|[p]rometheus|[g]rafana|[n]ginx|[p]ostgres|[m]ysql|[r]edis|[c]onsul|vault/ {print $11}' | sort -u | tr '\n' ' ' || echo "")

# ── Monitoring ────────────────────────────────────────────────────
MON_AGENTS=""
for svc in prometheus-node-exporter grafana-agent datadog-agent telegraf hetzner-monitoring-agent; do
  if systemctl is-active "$svc" &>/dev/null 2>&1; then MON_AGENTS="$MON_AGENTS $svc"; fi
done
[[ -n "$MON_AGENTS" ]] && MON_AGENTS=$(echo "$MON_AGENTS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

# ── Backups ───────────────────────────────────────────────────────
BACKUP_TOOLS=""
for t in borg restic velero snapper; do
  if command -v "$t" &>/dev/null 2>&1; then BACKUP_TOOLS="$BACKUP_TOOLS $t"; fi
  if systemctl is-active "$t" &>/dev/null 2>&1; then BACKUP_TOOLS="$BACKUP_TOOLS $t"; fi
done
[[ -n "$BACKUP_TOOLS" ]] && BACKUP_TOOLS=$(echo "$BACKUP_TOOLS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

# ── Management tools ──────────────────────────────────────────────
MGMT_TOOLS=""
for t in ansible terraform flux argocd helm; do
  if command -v "$t" &>/dev/null 2>&1; then MGMT_TOOLS="$MGMT_TOOLS $t"; fi
done
[[ -d /etc/ansible ]] && MGMT_TOOLS="$MGMT_TOOLS ansible-config"
[[ -d /opt/gitops ]] && MGMT_TOOLS="$MGMT_TOOLS gitops-dir"
[[ -n "$MGMT_TOOLS" ]] && MGMT_TOOLS=$(echo "$MGMT_TOOLS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

# ── Paquetes relevantes ───────────────────────────────────────────
PKGS=$(dpkg -l 2>/dev/null | awk '/^ii/{print $2"="$3}' | grep -E 'kubernetes|k3s|k0s|docker|containerd|crio|cilium|prometheus|grafana|nginx|postgres|mysql|redis|etcd|consul|vault|ansible|terraform|flux2|argocd' | tr '\n' ' ' || echo "")

# ── Emisión YAML ──────────────────────────────────────────────────
cat <<EOF
# Inventario generado el $DATE desde $HOSTNAME
# Script: hetzner-inventory.sh (smartiduran/inventory-scripts)
server:
  hostname: $(yaml_str "$HOSTNAME")
  fqdn: $(yaml_str "$(hostname -f 2>/dev/null || echo unknown)")
  date_collected: $(yaml_str "$DATE")
  os:
    pretty_name: $(yaml_str "$OS_PRETTY")
    id: $(yaml_str "$OS_ID")
    version_id: $(yaml_str "$OS_VERSION")
    kernel: $(yaml_str "$KERNEL")
    arch: $(yaml_str "$ARCH")
    uptime: $(yaml_str "$UPTIME")
  hardware:
    vcpu: $VCPU
    ram_gb: $RAM_GB
    root_disk_gb: $ROOT_GB
    disk_usage: $(yaml_str "$DISK_USE")
    disks: $(yaml_str "$DISKS")
  network:
    public_ipv4: $(yaml_str "$PUB_V4")
    public_ipv6: $(yaml_str "$PUB_V6")
    private_ips: $(yaml_str "$PRIV_IPS")
    default_interface: $(yaml_str "$DEF_IF")
    mac: $(yaml_str "$MAC")
  ssh:
    port: $SSH_PORT
    users: $(yaml_str "$SSH_USERS")
    authorized_keys_count: $AUTH_KEYS
    permit_root_login: $(yaml_str "$ROOT_LOGIN")
    password_authentication: $(yaml_str "$PASS_AUTH")
  firewall:
    tool: $(yaml_str "$FW_TOOL")
    rules_summary: $(yaml_str "$FW_RULES")
  systemd_services_running: $(yaml_str "$SERVICES")
  docker:
    running: $DOCKER_RUNNING
    containers: $(yaml_str "$DOCKER_CONTAINERS")
    container_names:
$(  for n in $CONTAINER_NAMES; do echo "      - $(yaml_str "$n")"; done)
$(  [[ -z "$CONTAINER_NAMES" ]] && echo "      []")
  kubernetes:
    distro: $(yaml_str "$K8S_DISTRO")
    version: $(yaml_str "$K8S_VERSION")
    cni: $(yaml_str "$CNI")
    csi: $(yaml_str "$CSI")
    ingress: $(yaml_str "$INGRESS")
    cert_manager: $CERT_MANAGER
    external_dns: $EXT_DNS
    nodes:
$(  for n in $K8S_NODES; do echo "      - $(yaml_str "$n")"; done)
$(  [[ -z "$K8S_NODES" ]] && echo "      []")
  key_processes: $(yaml_str "$KEY_PROCS")
  monitoring_agents:
$(  for a in $MON_AGENTS; do echo "    - $(yaml_str "$a")"; done)
$(  [[ -z "$MON_AGENTS" ]] && echo "    []")
  backup_tools:
$(  for b in $BACKUP_TOOLS; do echo "    - $(yaml_str "$b")"; done)
$(  [[ -z "$BACKUP_TOOLS" ]] && echo "    []")
  management_tools:
$(  for m in $MGMT_TOOLS; do echo "    - $(yaml_str "$m")"; done)
$(  [[ -z "$MGMT_TOOLS" ]] && echo "    []")
  relevant_packages: $(yaml_str "$PKGS")
EOF
