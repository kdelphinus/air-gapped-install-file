# 🚀 MetalLB v0.14.8 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr` (containerd CLI)을 사용하여 MetalLB를 설치하고 L2 로드밸런싱을 구성하는 절차입니다.

## 0단계: 네트워크 환경 확인 및 대역 산출 (필수)

MetalLB L2 모드는 노드와 동일한 물리 네트워크(L2 세그먼트) 내의 **유휴 IP**를 사용합니다. 이때 선정한 IP가 클러스터 내부 대역과 겹치지 않는지 확인해야 합니다.

### 1. 노드 네트워크 대역 확인

```bash
ip -4 addr show scope global | grep inet | awk '{print $2}'
ip route | grep default
```

### 🔍 노드 네트워크 확인 결과 (예시)

```text
$ ip -4 addr show scope global | grep inet | awk '{print $2}'
172.30.235.20/20

$ ip route | grep default
default via 172.30.224.1 dev eth0 proto kernel
```

위 출력에서 노드 네트워크 대역은 **`172.30.224.0/20`**이며, 게이트웨이 IP는 **`172.30.224.1`**입니다. MetalLB는 이 서브넷 범위 내에서 게이트웨이와 노드 IP를 제외한 유휴 IP를 사용해야 합니다.

### 2. Pod/Service CIDR 충돌 여부 확인

노드 서브넷과 Pod/Service CIDR이 다른 대역이라면(예: 노드 `172.x.x.x`, CIDR `10.x.x.x`) 이 단계는 생략 가능합니다. 같은 대역이라면(예: 노드 `10.0.0.x`, CIDR `10.42.0.0/16`) 반드시 아래 명령어로 충돌 여부를 확인하십시오.

```bash
# Pod CIDR 확인
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'

# Service CIDR 확인
kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'
```

### 🔍 클러스터 CIDR 확인 결과 (예시)

```text
$ kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
10.42.0.0/24

$ kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'
10.43.0.1
```

### ✅ IP 대역 선정 가이드 (설정 예시)

- **선정 기준**: 노드 서브넷에 속하면서 게이트웨이, 노드 IP, Pod/Service CIDR과 겹치지 않는 유휴 IP
- **할당 개수 기준**:
  - **최소 필요 (2~5개)**: Ingress 진입점 IP만 필요한 경우.
  - **권장 (20~30개)**: DevOps 도구별 독립 IP 부여 및 테스트 서비스 생성 목적.
  - **대규모 (50개 이상)**: 다수 서비스를 LoadBalancer로 직접 노출하거나 확장 고려 시.
- **추천 범위 (예시)**: `172.30.235.200-172.30.235.220` (약 20개 확보)

## 1단계: 이미지 로드 및 푸시 (Harbor)

오프라인 이미지 파일(`.tar`)을 노드에 로드하고 로컬 Harbor(`30002`)로 푸시합니다. 모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

### 1. 이미지 로드 (ctr 사용)

```bash
sudo ctr -n k8s.io images import images/quay.io-metallb-controller-v0.14.8.tar
sudo ctr -n k8s.io images import images/quay.io-metallb-speaker-v0.14.8.tar
```

### 2. Harbor push (업로드 스크립트 실행)

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: Helm 설치 (폴더 방식)

압축 해제된 차트 폴더를 사용하여 설치를 진행합니다.

```bash
# 네임스페이스 생성
kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치 (./charts/metallb 폴더 지정)
helm install metallb ./charts/metallb \
  -n metallb-system \
  -f values.yaml
```

## 3단계: IP 대역(L2) 설정

`manifests/l2-config.yaml` 파일을 열어 **0단계에서 산출한 유휴 IP 대역**을 `addresses` 항목에 설정합니다.

```yaml
# 예시: 0단계에서 확인한 대역 적용 (20개 할당)
spec:
  addresses:
    - 172.30.235.200-172.30.235.220
```

```bash
# 적용
kubectl apply -f manifests/l2-config.yaml
```

## 4단계: 설치 확인

### 1. 파드 및 설정 상태 확인

```bash
# 파드 상태 확인 (controller, speaker 모두 Running이어야 함)
kubectl get pods -n metallb-system

# IPAddressPool, L2Advertisement 적용 확인
kubectl get ipaddresspool,l2advertisement -n metallb-system
```

### 2. LoadBalancer IP 할당 확인

기존에 배포된 LoadBalancer 타입 서비스가 있다면 EXTERNAL-IP가 풀 대역 내 IP로 할당됐는지 확인합니다.

```bash
kubectl get svc -A | grep LoadBalancer
```

### 3. 동작 테스트 (CoreDNS 활용)

별도 이미지 없이 기존 파드를 이용해 빠르게 테스트할 수 있습니다.

```bash
# LoadBalancer 서비스 생성
kubectl expose deployment coredns -n kube-system \
  --name=metallb-test \
  --port=53 --protocol=UDP \
  --type=LoadBalancer

# IP 할당 확인 (수 초 내 할당됨)
kubectl get svc metallb-test -n kube-system -w

# 테스트 후 삭제
kubectl delete svc metallb-test -n kube-system
```
