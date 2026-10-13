# kubeadm 실습 환경

Multipass로 Ubuntu 24.04 VM을 띄웁니다. macOS(Intel / Apple Silicon)와 Ubuntu에서 똑같이 동작합니다.

| 구성 | 노드 | RAM 사용 |
|---|---|---|
| 기본 (`./up.sh`) | `cp1`, `w1`, `w2` | 약 6GB |
| HA (`./up.sh --ha`) | `cp1`, `cp2`, `cp3`, `w1`, `lb` | 약 8.5GB |

`lb`는 haproxy만 도는 VM입니다. `cp1~3:6443`으로 TCP를 분산하도록 설정까지 끝난 상태로 뜹니다.

## 준비

| OS | 설치 |
|---|---|
| macOS | `brew install --cask multipass` |
| Ubuntu | `sudo snap install multipass` |

권장 RAM은 기본 구성 12GB 이상, HA 구성 16GB 이상입니다. 8GB 장비는 `WORKER_MEM=1536M ./up.sh`로 줄이거나 클라우드 VM을 쓰세요.

## 사용법

```bash
./up.sh              # OS만 깔린 상태. swap/커널모듈/containerd/kubeadm 설치부터 직접 실습
./up.sh --prepped    # kubeadm init/join 직전 상태까지 자동 준비
./up.sh --ha         # HA 구성 (--prepped 와 같이 써도 됨)
./down.sh            # 전부 삭제 (망가지면 ./down.sh -y && ./up.sh)

multipass shell cp1  # 접속
```

- 기본 구성과 HA 구성을 바꿀 때는 `./down.sh`를 먼저 실행하세요.
- 노드끼리는 노드 이름(`cp1`, `w1`, `lb` 등)으로 접근할 수 있습니다 (`/etc/hosts`에 등록됨).
- `prep-node.sh`는 bare 모드 실습의 정답지입니다. 막히면 읽어보세요.
- k8s 버전은 `K8S_VERSION=v1.37 ./up.sh --prepped`처럼 바꿀 수 있습니다. 기본값 v1.36은 업그레이드 실습(1.36 → 1.37)을 하려고 한 단계 낮춰둔 것입니다.

## HA control plane

`./up.sh --ha --prepped`로 띄운 다음 진행합니다. kubeadm 부분은 실습이라 자동화하지 않았습니다.

**1. cp1에서 init.** endpoint는 반드시 `lb:6443`으로 지정합니다.

```bash
sudo kubeadm init \
  --control-plane-endpoint lb:6443 \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16
```

출력에 join 명령이 두 개 나옵니다. `--control-plane --certificate-key ...`가 붙은 것은 CP용이고, 붙지 않은 것은 worker용입니다. kubeconfig를 설정하고 CNI를 설치하세요.

**2. cp2, cp3에서 CP용 join, w1에서 worker용 join.**

certificate-key는 2시간 뒤 만료됩니다. 만료됐으면 cp1에서 다시 발급하세요.

```bash
sudo kubeadm init phase upload-certs --upload-certs   # 새 certificate-key
sudo kubeadm token create --print-join-command        # 새 join 명령
```

**3. 확인.**

```bash
kubectl get nodes
kubectl -n kube-system exec etcd-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

**4. 장애 테스트.** cp1의 control plane을 내리고 cp2에서 kubectl이 계속 되는지 봅니다.

```bash
# cp1에서
sudo systemctl stop kubelet
sudo crictl stop $(sudo crictl ps -q)

# cp2에서 (CP join하면 /etc/kubernetes/admin.conf가 생김)
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes

# 원복: cp1에서
sudo systemctl start kubelet
```

cp1이 바로 `NotReady`로 바뀌지 않아도 정상입니다. node-monitor-grace-period(기본 40초)가 지나야 바뀝니다.

`multipass stop cp1`으로 VM 자체를 내리는 방법은 쓰지 마세요. 다시 켤 때 IP가 바뀌면 클러스터가 깨집니다(아래 '주의' 참고).

CP를 2대 내리면 etcd quorum(3대 중 2대)이 깨져서 API가 멈춥니다. 이것도 한 번 확인해 볼 만합니다.

## 아키텍처 (Apple Silicon = arm64)

VM은 호스트와 같은 아키텍처로 뜹니다. `up.sh`가 호스트 아키텍처를 확인해서 VM 안에 `$ARCH`(`amd64` 또는 `arm64`)를 설정해 둡니다. apt로 설치하는 것들은 신경 쓸 필요가 없고, 바이너리를 직접 받을 때만 URL에 `$ARCH`를 쓰면 됩니다.

```bash
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/linux/${ARCH}/kubectl"
```

## 주의

**Pod CIDR은 `10.244.0.0/16`을 쓰세요.**
macOS Multipass VM 네트워크가 `192.168.64.0/24`라서 Calico 기본값 `192.168.0.0/16`과 겹칩니다.

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
```

Calico를 쓴다면 설치 매니페스트의 `CALICO_IPV4POOL_CIDR`(또는 Installation CR의 `cidr`)도 같은 값으로 맞춰야 합니다.

**VM IP가 바뀌면 클러스터가 깨집니다.**
macOS에서는 호스트 재부팅이나 `multipass restart` 후에 IP가 바뀔 수 있습니다. 이 경우 apiserver 인증서와 kubelet 설정이 예전 IP를 가리키게 됩니다. 고치려 하지 말고 `./down.sh -y && ./up.sh`로 다시 만드세요. 실습 중에는 VM을 재시작하지 않는 게 좋습니다.
