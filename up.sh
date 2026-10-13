#!/usr/bin/env bash
# kubeadm 실습용 VM을 Multipass로 띄운다. macOS / Ubuntu 공용.
#
#   ./up.sh            cp1, w1, w2               (기본 구성)
#   ./up.sh --ha       cp1, cp2, cp3, w1, lb     (HA control plane, lb = haproxy)
#   --prepped          containerd + kubeadm/kubelet/kubectl 설치까지 끝난 상태로
#
# 환경변수로 조정 가능:
#   K8S_VERSION=v1.36   설치할 k8s minor (--prepped 일 때만 사용)
#   CP_CPUS=2 CP_MEM=2G WORKER_CPUS=2 WORKER_MEM=2G DISK=20G LB_MEM=512M
#   UBUNTU_IMAGE=24.04
#
# macOS 기본 bash(3.2)에서도 돌아가야 하므로 bash 4 문법은 쓰지 않는다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# down.sh 의 ALL_NODES 와 맞출 것
ALL_NODES="cp1 cp2 cp3 w1 w2 lb"

K8S_VERSION="${K8S_VERSION:-v1.36}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-24.04}"
CP_CPUS="${CP_CPUS:-2}"
CP_MEM="${CP_MEM:-2G}"
WORKER_CPUS="${WORKER_CPUS:-2}"
WORKER_MEM="${WORKER_MEM:-2G}"
DISK="${DISK:-20G}"
LB_MEM="${LB_MEM:-512M}"

PREPPED=false
HA=false
for arg in "$@"; do
  case "$arg" in
    --prepped) PREPPED=true ;;
    --ha) HA=true ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 1 ;;
  esac
done

if [ "$HA" = true ]; then
  NODES="cp1 cp2 cp3 w1 lb"
  MIN_MEM_GB=16
else
  NODES="cp1 w1 w2"
  MIN_MEM_GB=12
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[주의]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[에러]\033[0m %s\n' "$*" >&2; exit 1; }

contains() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# --- 호스트 확인 ---------------------------------------------------------

HOST_OS="$(uname -s)"
case "$HOST_OS" in
  Darwin) INSTALL_HINT="brew install --cask multipass" ;;
  Linux)  INSTALL_HINT="sudo snap install multipass" ;;
  *) die "지원하지 않는 OS: $HOST_OS (macOS / Linux 만 지원)" ;;
esac

# Multipass VM은 호스트와 같은 아키텍처로 뜬다. 그래서 호스트 arch가 곧 VM arch.
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
esac

if [ "$HOST_OS" = Darwin ]; then
  HOST_MEM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
else
  HOST_MEM_GB=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
fi

command -v multipass >/dev/null 2>&1 || die "multipass가 없습니다. 설치: $INSTALL_HINT"

log "호스트: $HOST_OS / $ARCH / RAM ${HOST_MEM_GB}GB"
log "구성: $NODES"
log "모드: $([ "$PREPPED" = true ] && echo "prepped (k8s $K8S_VERSION)" || echo "bare")"

if [ "$HOST_MEM_GB" -lt "$MIN_MEM_GB" ]; then
  warn "RAM ${HOST_MEM_GB}GB: 이 구성은 ${MIN_MEM_GB}GB 이상을 권장합니다. 호스트가 많이 느려질 수 있습니다."
  warn "WORKER_MEM=1536M 처럼 줄이거나, 클라우드 VM 사용을 고려하세요."
fi

# --- 다른 구성의 VM이 남아 있는지 확인 -------------------------------------

vm_exists() { multipass info "$1" >/dev/null 2>&1; }

leftover=""
for node in $ALL_NODES; do
  if ! contains "$NODES" "$node" && vm_exists "$node"; then
    leftover="$leftover $node"
  fi
done
[ -z "$leftover" ] || die "다른 구성의 VM이 남아 있습니다:$leftover. 먼저 ./down.sh 를 실행하세요."

# --- VM 생성 -------------------------------------------------------------

for node in $NODES; do
  if vm_exists "$node"; then
    log "$node: 이미 있음, 건너뜀"
    continue
  fi
  case "$node" in
    cp*) cpus=$CP_CPUS; mem=$CP_MEM; disk=$DISK ;;
    w*)  cpus=$WORKER_CPUS; mem=$WORKER_MEM; disk=$DISK ;;
    lb)  cpus=1; mem=$LB_MEM; disk=5G ;;
  esac
  log "$node: 생성 중 (cpu=$cpus mem=$mem disk=$disk)"
  multipass launch "$UBUNTU_IMAGE" \
    --name "$node" --cpus "$cpus" --memory "$mem" --disk "$disk" \
    --cloud-init "$SCRIPT_DIR/cloud-init.yaml"
done

for node in $NODES; do
  multipass exec "$node" -- cloud-init status --wait >/dev/null \
    || die "$node: cloud-init 실패. 'multipass exec $node -- sudo cat /var/log/cloud-init-output.log' 확인"
done

# --- /etc/hosts 에 노드 이름 등록 (노드 이름으로 서로 찾도록) ---------------

node_ip() { multipass info "$1" | awk '/IPv4/ {print $2; exit}'; }

HOSTS_BLOCK=""
for node in $NODES; do
  ip="$(node_ip "$node")"
  [ -n "$ip" ] || die "$node: IP를 못 가져왔습니다"
  HOSTS_BLOCK="${HOSTS_BLOCK}${ip} ${node}
"
done

for node in $NODES; do
  multipass exec "$node" -- sudo bash -c "
    sed -i '/# BEGIN kubeadm-lab/,/# END kubeadm-lab/d' /etc/hosts
    printf '# BEGIN kubeadm-lab\n%s# END kubeadm-lab\n' '$HOSTS_BLOCK' >> /etc/hosts
    echo 'export ARCH=$ARCH' > /etc/profile.d/kubeadm-lab-arch.sh
  "
done

# --- HA: lb 에 haproxy (cp1~3:6443 로 TCP 분산) ----------------------------

if [ "$HA" = true ]; then
  log "lb: haproxy 설정 중"
  BACKENDS=""
  for node in cp1 cp2 cp3; do
    BACKENDS="${BACKENDS}    server ${node} $(node_ip "$node"):6443 check
"
  done
  multipass exec lb -- sudo bash -c "
    apt-get install -y -q haproxy >/dev/null
    cat > /etc/haproxy/haproxy.cfg <<'EOF'
global
    log /dev/log local0
    daemon

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend kube-apiserver
    bind *:6443
    default_backend kube-apiserver

backend kube-apiserver
    balance roundrobin
    default-server inter 2s fall 2 rise 2
${BACKENDS}EOF
    haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null
    systemctl restart haproxy
    systemctl enable haproxy >/dev/null
  "
fi

# --- prepped 모드: 노드 준비 스크립트 실행 (lb 제외) ------------------------

if [ "$PREPPED" = true ]; then
  for node in $NODES; do
    [ "$node" = lb ] && continue
    log "$node: containerd + kubeadm 설치 중"
    multipass transfer "$SCRIPT_DIR/prep-node.sh" "$node:/tmp/prep-node.sh"
    multipass exec "$node" -- sudo K8S_VERSION="$K8S_VERSION" bash /tmp/prep-node.sh
  done
fi

# --- 결과 ----------------------------------------------------------------

echo
multipass list | awk -v nodes=" $NODES " 'NR==1 || index(nodes, " " $1 " ")'
echo
log "완료. 접속: multipass shell cp1"
log "VM 안에서 \$ARCH=$ARCH 로 설정되어 있습니다 (바이너리 직접 받을 때 사용)."
[ "$HA" = false ] || log "HA 실습: README.md 의 'HA control plane' 절차를 따르세요 (endpoint = lb:6443)."
