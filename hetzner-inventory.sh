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

# Variables inicializadas para evitar "unbound variable" con set -u.
HOSTNAME="${HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}"
FQDN="$(hostname -f 2>/dev/null || echo "$HOSTNAME")"
DATE="$(date -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S%z")"

# Detectar si estamos ejecutando desde stdin (curl | bash) o desde archivo.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  HERE_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd || pwd)"
else
  HERE_DIR="$(pwd)"
fi

# ── helpers ────────────────────────────────────────────────────────
yaml_str() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  if [[ -z "$s" || "$s" =~ [\":,\[\]{}|>&!%@#\`'\''] || "$s" =~ ^\ *$ || "$s" =~ [\ ] ]]; then
    printf '"%s"\n' "$s"
  else
    printf '%s\n' "$s"
  fi
}
yaml_arr() {
  local k="$1"; shift
  if [[ $# -eq 0 ]]; then
    echo "$k: []"
    return
  fi
  echo "$k:"
  local v
  for v in "$@"; do
    printf '  - '
    yaml_str "$v"
  done
}

# ── Colección de datos ────────────────────────────────────────────
# OS
if [[ -f /etc/os-release ]]; then
  OS_PRETTY="$(awk -F= '/^PRETTY_NAME/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || echo 'unknown')"
  OS_ID="$(awk -F= '/^ID=/{print $2}' /etc/os-release 2>/dev/null || echo 'unknown')"
  OS_VERSION="$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release 2>/dev/null || echo 'unknown')"
else
  OS_PRETTY="unknown"
  OS_ID="unknown"
  OS_VERSION="unknown"
fi
KERNEL="$(uname -r 2>/dev/null || echo 'unknown')"
ARCH="$(uname -m 2>/dev/null || echo 'unknown')"
UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //' || uptime 2>/dev/null | awk '{print $3,$4,$5}' || echo 'unknown')"

# Hardware
VCPU="$(nproc 2>/dev/null || echo 'unknown')"
RAM_GB="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 'unknown')"
ROOT_GB="$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$2); print $2}')"
DISK_USE="$(df -h / 2>/dev/null | awk 'NR==2{print $5 " used of " $2}')"
DISK_INFO="$(lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | awk 'NR>1{gsub(/"/,""); print $1" "$2" "$3" "$4}' | tr '\n' ' ' || true)"
DISK_INFO="${DISK_INFO:-}"

# Red
PUB_V4="$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo 'unknown')"
PUB_V6="$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo 'unknown')"
PRIV_IPS="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | grep -v '^127\.' | tr '\n' ' ' || true)"
PRIV_IPS="${PRIV_IPS:-}"
DEF_IF="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
DEF_IF="${DEF_IF:-}"
MAC=""
if [[ -n "$DEF_IF" && -f "/sys/class/net/$DEF_IF/address" ]]; then
  MAC="$(cat "/sys/class/net/$DEF_IF/address" 2>/dev/null || true)"
fi
MAC="${MAC:-}"

# SSH
SSH_PORT="$(grep -E '^Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1 || true)"
SSH_PORT="${SSH_PORT:-22}"
SSH_USERS="$(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd 2>/dev/null | tr '\n' ' ' || true)"
SSH_USERS="${SSH_USERS:-}"
AUTH_KEYS=0
if [[ -d /home ]]; then
  AUTH_KEYS="$(find /home -name authorized_keys -type f 2>/dev/null -exec cat {} + 2>/dev/null | grep -c '^ssh-' || true)"
fi
ROOT_LOGIN="$(grep -E '^PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1 || true)"
ROOT_LOGIN="${ROOT_LOGIN:-}"
PASS_AUTH="$(grep -E '^PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1 || true)"
PASS_AUTH="${PASS_AUTH:-}"

# Firewall
FW_TOOL="none"
FW_RULES=""
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  FW_TOOL="ufw"
  FW_RULES="$(ufw status numbered 2>/dev/null | sed '1d' | head -20 | tr '\n' ' ' || true)"
elif command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q table; then
  FW_TOOL="nftables"
  FW_RULES="$(nft list ruleset 2>/dev/null | head -40 | tr '\n' ' ' || true)"
elif command -v iptables &>/dev/null && iptables -L -n 2>/dev/null | grep -q "^Chain"; then
  FW_TOOL="iptables"
  FW_RULES="$(iptables -L -n 2>/dev/null | head -30 | tr '\n' ' ' || true)"
fi
FW_RULES="${FW_RULES:-}"

# systemd services
SERVICES="$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -v '@' | sort -u | tr '\n' ' ' || true)"
SERVICES="${SERVICES:-}"

# Docker
DOCKER_RUNNING=false
DOCKER_CONTAINERS=""
CONTAINER_NAMES=""
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  DOCKER_RUNNING=true
  DOCKER_CONTAINERS="$(docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null | tr '\n' ' ' || true)"
  CONTAINER_NAMES="$(docker ps --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ' ' || true)"
fi
DOCKER_CONTAINERS="${DOCKER_CONTAINERS:-}"
CONTAINER_NAMES="${CONTAINER_NAMES:-}"

# Kubernetes
K8S_DISTRO="none"
K8S_VERSION="none"
CNI="none"
CSI="none"
INGRESS="none"
CERT_MANAGER="false"
EXT_DNS="false"
K8S_NODES=""
if command -v kubectl &>/dev/null && kubectl version --client &>/dev/null 2>&1; then
  K8S_VERSION="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo 'unknown')"
  if systemctl is-active k3s &>/dev/null 2>&1; then K8S_DISTRO="k3s"
  elif systemctl is-active k0s &>/dev/null 2>&1; then K8S_DISTRO="k0s"
  elif [[ -f /etc/talos/version.yaml ]]; then K8S_DISTRO="talos"
  elif systemctl is-active kubelet &>/dev/null 2>&1 && [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then K8S_DISTRO="kubeadm"
  fi
  if kubectl get pods -A -l k8s-app=cilium -o name &>/dev/null | grep -q .; then CNI="cilium"
  elif kubectl get pods -A -l k8s-app=flannel -o name &>/dev/null | grep -q .; then CNI="flannel"
  elif kubectl get pods -A -l app=calico -o name &>/dev/null | grep -q .; then CNI="calico"
  fi
  if kubectl get storageclass &>/dev/null 2>&1 | grep -q longhorn; then CSI="longhorn"
  elif kubectl get storageclass &>/dev/null 2>&1 | grep -q hcloud; then CSI="hcloud-csi"
  fi
  if kubectl get pods -A -l app.kubernetes.io/name=traefik &>/dev/null | grep -q .; then INGRESS="traefik"
  elif kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx &>/dev/null | grep -q .; then INGRESS="nginx"
  fi
  if kubectl get pods -A -l app.kubernetes.io/name=cert-manager &>/dev/null | grep -q .; then CERT_MANAGER="true"; fi
  if kubectl get pods -A -l app.kubernetes.io/name=external-dns &>/dev/null | grep -q .; then EXT_DNS="true"; fi
  K8S_NODES="$(kubectl get nodes -o name 2>/dev/null | awk -F/ '{print $2}' | tr '\n' ' ' || true)"
fi
K8S_NODES="${K8S_NODES:-}"

# Procesos clave
KEY_PROCS="$(ps aux 2>/dev/null | awk '/[k]ube-apiserver|[k]ube-controller|[k]ube-scheduler|[e]tcd|[c]ilium|[t]raefik|[p]rometheus|[g]rafana|[n]ginx|[p]ostgres|[m]ysql|[r]edis|[c]onsul|vault/ {print $11}' | sort -u | tr '\n' ' ' || true)"
KEY_PROCS="${KEY_PROCS:-}"

# Monitoring agents
MON_AGENTS=""
for svc in prometheus-node-exporter grafana-agent datadog-agent telegraf hetzner-monitoring-agent; do
  if systemctl is-active "$svc" &>/dev/null 2>&1; then
    MON_AGENTS="${MON_AGENTS}${svc} "
  fi
done
MON_AGENTS="${MON_AGENTS% }"

# Backup tools
BACKUP_TOOLS=""
for t in borg restic velero snapper; do
  if command -v "$t" &>/dev/null 2>&1; then BACKUP_TOOLS="${BACKUP_TOOLS}${t} "; fi
  if systemctl is-active "$t" &>/dev/null 2>&1; then BACKUP_TOOLS="${BACKUP_TOOLS}${t} "; fi
done
BACKUP_TOOLS="${BACKUP_TOOLS% }"

# Management tools
MGMT_TOOLS=""
for t in ansible terraform flux argocd helm; do
  if command -v "$t" &>/dev/null 2>&1; then MGMT_TOOLS="${MGMT_TOOLS}${t} "; fi
done
[[ -d /etc/ansible ]] && MGMT_TOOLS="${MGMT_TOOLS}ansible-config "
[[ -d /opt/gitops ]] && MGMT_TOOLS="${MGMT_TOOLS}gitops-dir "
MGMT_TOOLS="${MGMT_TOOLS% }"

# Paquetes relevantes
PKGS="$(dpkg -l 2>/dev/null | awk '/^ii/{print $2"="$3}' | grep -E 'kubernetes|k3s|k0s|docker|containerd|crio|cilium|prometheus|grafana|nginx|postgres|mysql|redis|etcd|consul|vault|ansible|terraform|flux2|argocd' | tr '\n' ' ' || true)"
PKGS="${PKGS:-}"

# ── Emit YAML ──────────────────────────────────────────────────────
cat <<EOF
# Inventario generado el $DATE desde $HOSTNAME
# Script: hetzner-inventory.sh (smartiduran/inventory-scripts)
server:
  hostname: $(yaml_str "$HOSTNAME")
  fqdn: $(yaml_str "$FQDN")
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
    disks: $(yaml_str "$DISK_INFO")
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
