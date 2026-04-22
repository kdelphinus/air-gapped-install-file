# MetalLB v0.14.8 오프라인 설치 가이드

폐쇄망 환경에서 MetalLB(L2 모드)를 설치하여 Bare-metal K8s 클러스터에 LoadBalancer 타입
서비스를 제공하는 절차입니다. 모든 명령은 **컴포넌트 루트 디렉토리**(`metallb-0.14.8/`)에서 실행합니다.

## 전제 조건

- Kubernetes 클러스터가 정상 동작 중 (`kubectl get nodes` → `Ready`)
- 오프라인 이미지 및 Helm 차트가 본 디렉토리에 준비되어 있음 (`images/`, `charts/`)
- (권장) Harbor 레지스트리가 `NODE_IP:30002` 로 동작 중 — 로컬 이미지 직접 사용도 가능
- **kube-proxy strictARP 활성화** — kube-proxy 가 IPVS 모드로 동작 중이라면 필수

  ```bash
  kubectl get configmap kube-proxy -n kube-system -o yaml | grep -E 'mode|strictARP'
  # mode: "ipvs" 이면 아래 명령으로 strictARP: true 로 변경
  kubectl get configmap kube-proxy -n kube-system -o yaml \
    | sed -e "s/strictARP: false/strictARP: true/" \
    | kubectl apply -f - -n kube-system
  kubectl rollout restart daemonset kube-proxy -n kube-system
  ```

## 아키텍처 개요

```text
┌──────────────────────────────────────────────────────┐
│  metallb-system 네임스페이스                          │
│                                                       │
│  ┌─────────────────┐      ┌────────────────────────┐ │
│  │  controller     │      │  speaker (DaemonSet)   │ │
│  │  (Deployment)   │◀────▶│  — 모든 노드에 배포     │ │
│  │  IP 할당 관리    │      │  L2 ARP 응답 처리       │ │
│  └─────────────────┘      └────────────────────────┘ │
└──────────────────────────────────────────────────────┘
         ▲
         │ spec 제공 (user input)
         ▼
┌──────────────────────────────────────────────────────┐
│  IPAddressPool  :  172.30.235.200-172.30.235.220     │
│  L2Advertisement: 위 풀을 L2(ARP)로 광고             │
└──────────────────────────────────────────────────────┘
```

## 0단계: IP 대역 산출

MetalLB L2 모드는 노드와 동일한 물리 네트워크(L2 세그먼트) 내의 **유휴 IP**를 사용합니다.

### 노드 네트워크 확인

```bash
ip -4 addr show scope global | grep inet | awk '{print $2}'
ip route | grep default
```

예시 출력:

```text
172.30.235.20/20
default via 172.30.224.1 dev eth0
```

→ 노드 서브넷: `172.30.224.0/20`, 게이트웨이: `172.30.224.1`

### Pod/Service CIDR 충돌 확인

```bash
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'
```

노드 서브넷이 Pod/Service CIDR 과 다른 대역이면 충돌 걱정 없음.
같은 대역이면 반드시 위 출력을 확인하여 겹치지 않도록 IP 풀을 선정하세요.

### IP 풀 선정 가이드

- **선정 기준**: 노드 서브넷에 속하면서 게이트웨이·노드 IP·Pod/Service CIDR 과 겹치지 않는 유휴 IP
- **권장 할당 수**: 최소 2~5개(Ingress 진입점용) / 권장 20~30개(서비스별 독립 IP) / 대규모 50개 이상
- **예시**: `172.30.235.200-172.30.235.220` (약 20개)

## 1단계: 이미지 확보 및 로드

### 방법 A — 로컬 이미지 직접 사용 (권장: 단일 노드/테스트)

`install.sh` 가 자동으로 `./images/*.tar*` 를 `ctr -n k8s.io images import` 로 로드합니다.
수동으로 할 경우:

```bash
sudo ctr -n k8s.io images import ./images/quay.io-metallb-controller-v0.14.8.tar
sudo ctr -n k8s.io images import ./images/quay.io-metallb-speaker-v0.14.8.tar
```

### 방법 B — Harbor 레지스트리 사용 (멀티 노드 환경 권장)

```bash
chmod +x ./images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

업로드 완료 후 Harbor UI 에서 `library/metallb-controller`, `library/metallb-speaker` 태그가
보이는지 확인합니다.

## 2단계: 설치 및 업그레이드

### 방법 1. 자동화 스크립트 사용 (권장)

```bash
sudo ./scripts/install.sh
```

대화형 프롬프트:

| 순서 | 항목 | 비고 |
| :--- | :--- | :--- |
| 1 | 이미지 소스 (Harbor / 로컬) | Harbor 선택 시 주소·프로젝트 입력 |
| 2 | LoadBalancer IP 풀 | `start-end` 형식 (예: `172.30.235.200-172.30.235.220`) |

기존 설치 또는 `install.conf` 가 감지되면 다음 메뉴가 표시됩니다:

| 메뉴 | 동작 |
| :--- | :--- |
| 1) 업그레이드 | 저장된 설정을 유지하고 `helm upgrade` 수행 |
| 2) 재설치 | 기존 리소스 삭제 후 처음부터 재입력 |
| 3) 초기화 | 네임스페이스·`install.conf` 포함 완전 삭제 |
| 4) 취소 | 아무 동작 없이 종료 |

### 방법 2. Manual Installation & Upgrade

자동화 스크립트를 사용하지 않고 수동으로 수행하는 경우:

```bash
# 1. IP 풀 수정
vi ./manifests/l2-config.yaml     # spec.addresses 의 - <range> 를 본인 환경에 맞게 수정

# 2. (Harbor 사용 시) values.yaml 의 이미지 경로를 본인 환경에 맞게 수정
vi ./values.yaml                  # <NODE_IP>:30002/library/... 를 실제 주소로 변경

# 3. Helm 설치/업그레이드
helm upgrade --install metallb ./charts/metallb \
  -n metallb-system --create-namespace \
  -f ./values.yaml

# 4. controller / speaker 기동 대기
kubectl wait --timeout=5m -n metallb-system deployment/metallb-controller --for=condition=Available
kubectl rollout status daemonset/metallb-speaker -n metallb-system --timeout=5m

# 5. IPAddressPool / L2Advertisement 적용
kubectl apply -f ./manifests/l2-config.yaml
```

## 3단계: 설치 검증

### 파드 및 CR 상태 확인

```bash
kubectl get pods -n metallb-system
# NAME                                  READY   STATUS    ...
# metallb-controller-xxxxxxx-xxxxx      1/1     Running   ...
# metallb-speaker-xxxxx                 4/4     Running   ...

kubectl get ipaddresspool,l2advertisement -n metallb-system
```

### 동작 테스트 (CoreDNS 활용)

```bash
# LoadBalancer 서비스 생성
kubectl expose deployment coredns -n kube-system \
  --name=metallb-test --port=53 --protocol=UDP \
  --type=LoadBalancer

# 수 초 내 EXTERNAL-IP 가 풀 범위 내 값으로 할당되어야 함
kubectl get svc metallb-test -n kube-system

# 테스트 후 삭제
kubectl delete svc metallb-test -n kube-system
```

## 4단계: 삭제 및 초기화

### 자동화

```bash
sudo ./scripts/install.sh
# → 메뉴에서 "3) 초기화" 선택
```

### 수동

```bash
helm uninstall metallb -n metallb-system
# CR finalizer 가 남아 ns 삭제가 지연되는 경우
for KIND in ipaddresspool l2advertisement bgpadvertisement bgppeer; do
  kubectl get $KIND -n metallb-system -o name 2>/dev/null \
    | xargs -r -I {} kubectl patch {} -n metallb-system \
        -p '{"metadata":{"finalizers":[]}}' --type=merge
done
kubectl delete ns metallb-system
rm -f ./install.conf
```

## 참고 — BGP 모드

현재 본 설치 패키지는 **L2 모드 전용**입니다. BGP 모드(frr-k8s 기반)는 향후 지원 예정이며,
수동 구성이 필요한 경우 `charts/metallb/values.yaml` 의 `frrk8s.enabled` 및 `speaker.frr.enabled`
를 활성화한 뒤 `BGPPeer` / `BGPAdvertisement` 매니페스트를 직접 작성해야 합니다.
