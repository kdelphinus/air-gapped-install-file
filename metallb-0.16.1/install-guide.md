# MetalLB v0.16.1 오프라인 설치 가이드

폐쇄망 환경에서 MetalLB(L2 모드)를 설치하여 Bare-metal K8s 클러스터에 LoadBalancer 타입 서비스를 제공하는 절차입니다. 모든 명령은 **컴포넌트 루트 디렉토리**(`metallb-0.16.1/`)에서 실행합니다.

> [!IMPORTANT]
> **L2 전용 모드 고정 및 BGP 미지원 안내**
> 본 패키지는 오프라인 환경에 맞춘 L2 ARP 전용 구성입니다. BGP(FRR) 모드는 오프라인 수집 대상 및 기술 지원 범위에서 명시적으로 제외됩니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/metallb/` 디렉토리에 압축 해제된 차트 본체가 생성되고, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 1. 전제 조건

- Kubernetes 클러스터가 정상 동작 중 (`kubectl get nodes` → `Ready`)
- 오프라인 이미지 및 Helm 차트가 준비되어 있음 (`images/`, `charts/`)
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

---

## 2. 아키텍처 개요

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

---

## 3. 0단계: IP 대역 산출

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
- **주의**: 중복되거나 잘못 지정된 IP 대역은 전체 노드의 ARP 응답 충돌을 초래하여 망 장애를 유발할 수 있습니다.
- **예시**: `172.30.235.200-172.30.235.220` (약 20개)

---

## 4. 1단계: 이미지 확보 및 로드

### 방법 A — 로컬 이미지 직접 사용 (단일 노드/테스트 환경)

`install.sh` 가 자동으로 `./images/*.tar*` 를 `ctr -n k8s.io images import` 로 로드합니다.
수동으로 수행할 경우:

```bash
sudo ctr -n k8s.io images import ./images/quay.io-metallb-controller-v0.16.1.tar
sudo ctr -n k8s.io images import ./images/quay.io-metallb-speaker-v0.16.1.tar
```

### 방법 B — Harbor 레지스트리 사용 (멀티 노드 환경 권장)

```bash
chmod +x ./images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

업로드 완료 후 Harbor UI 에서 `library/metallb-controller`, `library/metallb-speaker` 태그가 보이는지 확인합니다.

---

## 5. 2단계: 설치 및 업그레이드

> [!WARNING]
> **트래픽 단절 영향 경고**
> `Upgrade`를 제외한 `Uninstall` 및 `Reinstall(재설치)` 메뉴 수행 시, controller/speaker DaemonSet이 일시적 또는 완전히 철거되므로 **기존의 모든 외부 LoadBalancer IP 통신망이 전면 즉시 단절**됩니다. 운영 환경인 경우 각별히 주의하시기 바랍니다.

### 방법 1. 자동화 스크립트 사용 (권장)

```bash
sudo ./scripts/install.sh
```

대화형 프롬프트:

| 순서 | 항목 | 비고 |
| :--- | :--- | :--- |
| 1 | 이미지 소스 (Harbor / 로컬) | Harbor 선택 시 주소·프로젝트 입력 |
| 2 | LoadBalancer IP 풀 | `start-end` 형식 (예: `172.30.235.200-172.30.235.220`) |
| 3 | IPAddressPool 이름 | DNS label 형식 검증 적용 (예: `cluster-pool`) |

기존 설치 또는 `install.conf` 가 감지되면 다음 메뉴가 표시됩니다:

| 메뉴 | 동작 |
| :--- | :--- |
| 1) 업그레이드 | 저장된 설정을 유지하고 `helm upgrade` 수행 (무중단 권장) |
| 2) 재설치 | Namespace/IP 풀은 안전하게 보존하며 release만 삭제 후 재구축 (일시 중단 경고) |
| 3) 초기화 | IP 풀, 네임스페이스 및 모든 설정 자산 전면 파괴 (2차 y/N 확인 진행) |
| 4) 취소 | 아무 동작 없이 종료 |

### 방법 2. Manual Installation & Upgrade (수동 설치 지침)

자동화 스크립트를 사용하지 않고 수동으로 수행하는 경우:

```bash
# 1. 수동 values-infra.yaml 작성 (오염 방지용)
cat > values-infra.yaml <<EOF
controller:
  image:
    repository: "192.168.1.10:30002/library/metallb-controller"
    tag: v0.16.1
speaker:
  image:
    repository: "192.168.1.10:30002/library/metallb-speaker"
    tag: v0.16.1
EOF

# 2. Helm 설치/업그레이드
helm upgrade --install metallb ./charts/metallb \
  -n metallb-system --create-namespace \
  -f values.yaml -f values-infra.yaml

# 3. controller / speaker 기동 대기
kubectl wait --timeout=5m -n metallb-system deployment/metallb-controller --for=condition=Available
kubectl rollout status daemonset/metallb-speaker -n metallb-system --timeout=5m

# 4. IPAddressPool / L2Advertisement 수동 치환 적용
# (실제 production-pool 이름 및 192.168.10.50-192.168.10.60 IP 대역 치환 예시)
sed \
  -e "s|cluster-pool|production-pool|g" \
  -e "s|172.30.235.200-172.30.235.210|192.168.10.50-192.168.10.60|g" \
  ./manifests/l2-config.yaml | kubectl apply -f -
```

---

## 6. 3단계: 설치 검증

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

---

## 7. 4단계: 삭제 및 초기화

### 자동화 (스크립트 사용)

```bash
# 일반 삭제 (Namespace 및 설정 데이터 안전 보존)
# ⚠️ [경고] controller/speaker 제거로 모든 LoadBalancer 외부 통신이 즉시 중단됩니다.
sudo ./scripts/uninstall.sh

# 완전 삭제 (Namespace 및 IP 풀 완전 제거)
# ⚠️ [주의] 네임스페이스와 IPAddressPool 등 리소스가 완전히 삭제됩니다.
sudo ./scripts/uninstall.sh --reset
```

### 수동 삭제

- **일반 수동 삭제 (Namespace 및 설정 데이터 보존)**:
  - ⚠️ [주의] controller/speaker 제거로 모든 LoadBalancer 외부 통신이 즉시 중단됩니다.
  ```bash
  helm uninstall metallb -n metallb-system
  ```

- **완전 수동 삭제 (Namespace 및 IP 풀 완전 제거)**:
  - ⚠️ [주의] `metallb-system` 네임스페이스가 삭제되면서 네임스페이스 내의 `IPAddressPool` 및 `L2Advertisement` 설정도 물리적으로 완전히 제거됩니다.
  ```bash
  helm uninstall metallb -n metallb-system

  for KIND in ipaddresspool l2advertisement bgpadvertisement bgppeer community bfdprofile; do
    kubectl get $KIND -n metallb-system -o name 2>/dev/null \
      | xargs -r -I {} kubectl patch {} -n metallb-system \
          -p '{"metadata":{"finalizers":[]}}' --type=merge
  done

  kubectl delete ns metallb-system
  rm -f ./install.conf values-infra.yaml
  ```
