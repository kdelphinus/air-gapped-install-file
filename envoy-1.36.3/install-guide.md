# Envoy Gateway v1.36.3 오프라인 설치 가이드

폐쇄망 환경에서 Envoy Gateway를 Kubernetes 위에 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `images/envoy-gateway.tar` | Envoy Gateway 컨트롤러 이미지 |
| `images/envoy-proxy.tar` | Envoy Proxy 데이터 플레인 이미지 |
| `images/upload_images.sh` | Harbor 이미지 업로드 스크립트 |
| `gateway-1.6.1/` | Envoy Gateway Controller Helm 차트 |
| `strato-gateway-infra/` | Infrastructure Helm 차트 (GatewayClass, Gateway 정의) |
| `install_envoy-gateway.sh` | 설치 자동화 스크립트 |
| `policy-global-config.yaml` | 전역 정책 설정 (EnvoyPatchPolicy 등) |

## Phase 1: 이미지 Harbor 업로드

```bash
cd images

# upload_images.sh 상단 Config 수정
# HARBOR_REGISTRY, HARBOR_PROJECT, HARBOR_USER, HARBOR_PASSWORD 항목

chmod +x upload_images.sh
./upload_images.sh
```

## Phase 2: 설치 스크립트 변수 설정

`install_envoy-gateway.sh` 상단 설정 변수를 환경에 맞게 수정합니다.

| 변수 | 설명 | 기본값 |
| :--- | :--- | :--- |
| `NAMESPACE` | 설치 네임스페이스 | `envoy-gateway-system` |
| `GW_NAME` | Gateway 리소스 이름 | `cmp-gateway` |
| `GW_CLASS_NAME` | GatewayClass 이름 | `eg-cluster-entry` |
| `IMG_GATEWAY` | Envoy Gateway 이미지 주소 | Harbor 주소로 변경 |
| `IMG_PROXY` | Envoy Proxy 이미지 주소 | Harbor 주소로 변경 |

## Phase 3: 설치 실행

```bash
chmod +x install_envoy-gateway.sh
./install_envoy-gateway.sh
```

스크립트 실행 중 아래 항목을 인터랙티브하게 선택합니다.

1. 기존 설치 감지 시: 삭제 후 재설치 여부 (y/n)
2. 설치 모드 선택:
   - `1` — LoadBalancer Mode (HostNetwork/MetalLB)
   - `2` — NodePort Mode (권장, 30080/30443 포트)
3. 노드 고정 여부: 특정 노드 이름 입력 또는 Enter로 자동 배치
4. 전역 정책 적용 여부 (`policy-global-config.yaml`)

## Phase 4: 설치 확인

```bash
kubectl get pods -n envoy-gateway-system
kubectl get gateway -n envoy-gateway-system
kubectl get svc -n envoy-gateway-system
```

NodePort 모드 포트 확인:

```bash
netstat -tlpn | grep 30443
```

## Phase 5: 서비스 노출 (HTTPRoute 생성)

신규 서비스를 Envoy Gateway를 통해 노출하려면 HTTPRoute 리소스를 생성합니다.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-service-route
  namespace: my-namespace
spec:
  parentRefs:
    - name: cmp-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "my-service.internal"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-service
          port: 80
```

```bash
kubectl apply -f my-service-route.yaml
```

## 배포 모드 선택 기준

| 요구사항 | 권장 모드 |
| :--- | :--- |
| 클라이언트 실IP 보존 필요 (접근 로그, IP 차단 등) | `Local + DaemonSet` |
| 단순 라우팅만 필요 (IP 불필요, 단일 노드) | `Cluster + Deployment` |
