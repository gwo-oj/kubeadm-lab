#!/usr/bin/env bash
# 노드 하나를 kubeadm init/join 직전 상태로 만든다. VM 안에서 root로 실행.
#   sudo K8S_VERSION=v1.36 bash prep-node.sh
# bare 모드로 띄운 뒤 "정답 확인용"으로 읽어봐도 된다. 순서가 곧 실습 순서.
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.36}"
[ "$(id -u)" -eq 0 ] || { echo "root로 실행하세요 (sudo)" >&2; exit 1; }

# 1. swap off
swapoff -a
sed -i '/\sswap\s/ s/^#*/#/' /etc/fstab

# 2. 커널 모듈 + sysctl
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# 3. containerd (systemd cgroup driver)
apt-get update -q
apt-get install -y -q containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
  || { echo "containerd config에서 SystemdCgroup 설정을 못 찾음 (containerd 버전 확인)" >&2; exit 1; }
systemctl restart containerd
systemctl enable containerd >/dev/null

# 4. kubeadm / kubelet / kubectl (pkgs.k8s.io, arch는 apt가 알아서 맞춤)
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null

# 5. crictl이 containerd를 바라보게
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF

echo "$(hostname): 준비 완료 ($(kubeadm version -o short))"
