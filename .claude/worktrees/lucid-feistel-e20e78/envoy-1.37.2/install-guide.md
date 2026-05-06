# Envoy Gateway v1.7.2 / Proxy v1.37.2 오프라인 설치 가이드

폐쇄망 환경에서 Envoy Gateway를 Kubernetes(K8s) 위에 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 이상 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 또는 로컬 이미지 로드 환경 (Containerd `ctr` 등)

## 아키텍처 개요

- **Network:** `hostNetwork: false` (Pod 격리 보호)
- **트래픽 진입점:** `LoadBalancer` 또는 `NodePort` 서비스
- **구성 요소:**
  - **Control Plane:** Envoy Gateway v1.7.2
  - **Data Plane:** Envoy Proxy v1.37.2 (Distroless)

### 배포 모드 비교 및 선택

| 항목 | LoadBalancer + DaemonSet (권장) | NodePort + DaemonSet |
| :--- | :--- | :--- |
| **권장 환경** | 클라우드 또는 MetalLB 환경 | 하드웨어 L4 / HAProxy 연동 환경 |
| **실IP 보존** | 가능 (`externalTrafficPolicy: Local`) | 가능 (Proxy Protocol 필요 시 설정) |
| **고가용성(HA)** | 모든 워커 노드에서 트래픽 수신 | 모든 워커 노드에서 트래픽 수신 |
| **운영 편의성** | 높음 (자동 IP 관리) | 보통 (Port 관리 및 LB 연동 필요) |

---

## 1단계: 이미지 확보 및 로드

### Case A: 로컬 환경에 직접 로드 (Harbor 미사용 시)

인터넷이 되는 환경에서 이미지를 Pull 한 뒤 tar로 확보하여 워커 노드로 옮깁니다.

```bash
# 이미지 Pull 및 Export (인터넷 가능 환경)
ctr images pull docker.io/envoyproxy/gateway:v1.7.2
ctr images pull docker.io/envoyproxy/envoy:distroless-v1.37.2
ctr images export envoy-gateway.tar docker.io/envoyproxy/gateway:v1.7.2
ctr images export envoy-proxy.tar docker.io/envoyproxy/envoy:distroless-v1.37.2

# 폐쇄망 워커 노드에서 Import (Kubernetes 네임스페이스 지정)
sudo ctr -n k8s.io images import envoy-gateway.tar
sudo ctr -n k8s.io images import envoy-proxy.tar
```

*(참고: K3s를 사용하는 경우 `sudo k3s ctr -n k8s.io images import ...` 명령어를 사용하십시오.)*

### Case B: Harbor 레지스트리 업로드

```bash
chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

---

## 2단계: 설치 및 업그레이드

설치는 자동화 스크립트를 사용하거나, 수동으로 Helm 명령어를 직접 실행하여 진행할 수 있습니다.

### 방법 1. 자동화 스크립트 사용 (권장)

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

**스크립트 동작 모드 설명:**

1. **업그레이드**: `install.conf`에 저장된 이전 설정을 유지하며 Helm Upgrade를 수행합니다. **기존 HTTPRoute 등 설정이 보존됩니다.**
2. **재설치**: 기존 Helm 리소스를 삭제한 후 새로 입력받은 설정으로 설치합니다.
3. **초기화**: 모든 리소스와 `install.conf`를 삭제합니다.

### 방법 2. 수동 설치 및 업그레이드 (스크립트 사용 불가 시)

스크립트 환경에 문제가 있거나 세밀한 제어가 필요할 경우 아래 순서대로 직접 실행합니다.

#### 1) CRD 수동 적용 (설치/업그레이드 공통)

Envoy Gateway는 Helm 배포 전에 CRD를 먼저 적용해야 합니다.

```bash
# 디렉토리 이동
cd envoy-1.37.2/

# CRD 적용 (어노테이션 크기 문제 방지를 위해 replace --force 권장)
kubectl replace --force -f charts/gateway-1.7.2/crds/gatewayapi-crds.yaml
kubectl replace --force -f charts/gateway-1.7.2/crds/generated/
```

#### 2) 컨트롤 플레인 설치/업그레이드

`values.yaml` 파일을 환경(이미지 경로 등)에 맞게 수정한 뒤 실행합니다.

```bash
helm upgrade --install eg-gateway ./charts/gateway-1.7.2 \
  -n envoy-gateway-system --create-namespace \
  -f ./values.yaml
```

#### 3) 데이터 플레인 (인프라) 설치/업그레이드

`values-infra.yaml` 파일을 환경에 맞게 수정한 뒤 실행합니다.

```bash
helm upgrade --install gateway-infra ./charts/gateway-infra \
  -n envoy-gateway-system \
  -f ./values-infra.yaml
```

#### 4) 전역 정책 적용 (선택)

```bash
kubectl apply -f manifests/policy-global-config.yaml
```

---

## 3단계: 배포 후 네트워크 구성 (심화)

### 1. LoadBalancer — 수동 IP 할당 (온프레미스/DaemonSet)

전체 워커 노드 IP를 `externalIPs`에 등록하여 고가용성을 확보합니다. 서비스(Service) 뿐만 아니라 게이트웨이(Gateway) 리소스에도 주소를 명시적으로 바인딩해야 정상적으로 가동(`Programmed: True`)됩니다.

#### 1) 서비스(Service) 외부 IP 등록

```bash
# 서비스 이름 확인
SVC_NAME=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=cluster-gateway -o jsonpath='{.items[0].metadata.name}')

# 단일 노드 IP 등록 시
kubectl patch svc -n envoy-gateway-system $SVC_NAME --type merge \
  -p '{"spec":{"externalIPs":["[Worker1 IP]"]}}'

# 전체 워커 노드 IP 일괄 등록 시 (다중 노드 환경)
kubectl patch svc -n envoy-gateway-system $SVC_NAME --type merge \
  -p '{"spec":{"externalIPs":["[Worker1 IP]","[Worker2 IP]","[Worker3 IP]"]}}'
```

#### 2) 게이트웨이(Gateway) 리소스 주소 바인딩

서비스 패치 후에도 Gateway 상태가 `False`인 경우 아래 명령어로 주소를 직접 바인딩합니다.

```bash
# 단일 노드 IP 바인딩
kubectl patch gateway cluster-gateway -n envoy-gateway-system --type='merge' \
  -p '{"spec":{"addresses":[{"type":"IPAddress","value":"[Worker1 IP]"}]}}'

# 다중 노드 IP 바인딩 (전체 워커 노드 등록 권장)
kubectl patch gateway cluster-gateway -n envoy-gateway-system --type='merge' \
  -p '{"spec":{"addresses":[
    {"type":"IPAddress","value":"[Worker1 IP]"},
    {"type":"IPAddress","value":"[Worker2 IP]"},
    {"type":"IPAddress","value":"[Worker3 IP]"}
  ]}}'
```

> **주의**: `[Worker1 IP]`, `[Worker2 IP]` 등의 부분은 실제 환경의 워커 노드 IP 주소로 변경하여 실행해야 합니다.

### 2. NodePort — 포트 확인 및 HAProxy 연동

`values-infra.yaml`에서 NodePort로 설정한 경우 할당된 포트(기본 30080, 30443)를 확인합니다.

```bash
kubectl get svc -n envoy-gateway-system
# 출력 예: 80:30080/TCP, 443:30443/TCP
```

해당 포트를 앞단의 HAProxy 또는 L4 스위치의 Real Server 포트로 지정합니다.

### 3. 와일드카드 TLS 인증서 적용

`*.devops.internal`과 같은 통합 인증서를 적용하는 절차입니다.

**TLS Secret 생성:**

```bash
kubectl create secret tls wildcard-tls-secret \
  --cert=cert.pem --key=key.pem -n envoy-gateway-system
```

**Gateway 리스너 설정 업데이트 (`gateway-infra` 템플릿 또는 수동 패치):**

```yaml
spec:
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.devops.internal"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-tls-secret
            kind: Secret
```

---

## 4단계: 서비스 노출 (HTTPRoute)

신규 서비스를 Envoy를 통해 노출하려면 HTTPRoute 리소스를 생성합니다.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: example-service
  namespace: default
spec:
  parentRefs:
    - name: cluster-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "app.devops.internal"
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: app-svc
          port: 80
```

---

## 삭제 및 초기화

자동화 스크립트를 사용하거나 수동으로 리소스를 제거합니다.

```bash
# 스크립트 사용
./scripts/uninstall.sh

# 수동 삭제
helm uninstall gateway-infra -n envoy-gateway-system
helm uninstall eg-gateway -n envoy-gateway-system
kubectl delete ns envoy-gateway-system
```
