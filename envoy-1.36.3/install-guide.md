# Envoy Gateway v1.36.3 오프라인 설치 가이드

폐쇄망 환경에서 Envoy Gateway를 Kubernetes 위에 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)

## 아키텍처 개요

쿠버네티스 보안 및 네트워크 표준을 준수하는 구성입니다.

- **Network:** `hostNetwork: false` (Pod는 K8s 내부망 사용, 노드 네트워크와 격리)
- **Service:** `type: LoadBalancer` 또는 `type: NodePort` (외부 트래픽 진입점)
- **트래픽 흐름 (LoadBalancer):**

  ```text
  Client → External IP (LB) → Service (80/443) → Envoy Pod → Backend Pod
  ```

- **트래픽 흐름 (NodePort + VIP):**

  ```text
  Client → VIP (HAProxy) → Worker Node IP:30080/30443 → Envoy Pod → Backend Pod
  ```

## 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: 설치 및 운영 설정 (values.yaml)

루트 디렉토리의 설정 파일들을 환경에 맞게 수정합니다.

| 파일명 | 용도 | 비고 |
| :--- | :--- | :--- |
| `values-controller.yaml` | Envoy Gateway Controller 설정 | 이미지 경로 및 리소스 제한 등 |
| `values-infra.yaml` | Infrastructure (Gateway) 설정 | 서비스 타입(LB/NodePort), 포트 등 |
| `manifests/policy-global.yaml` | 전역 보안 및 트래픽 정책 | EnvoyPatchPolicy 등 |

## 3단계: TLS 사전 구성 (HTTPS 사용 시)

HTTPS를 사용할 경우 Helm 배포 전 Gateway 네임스페이스에 TLS Secret을 생성합니다.

```bash
# 네임스페이스 생성 (없는 경우)
kubectl create ns envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f -

# TLS Secret 생성
kubectl create secret tls strato-tls \
  --cert=cert.pem \
  --key=key.pem \
  --namespace envoy-gateway-system
```

추가 인증서가 있으면 Secret을 각각 생성한 뒤 `manifests/gateway.yaml`의 `listeners` 항목에 추가합니다.

HTTP만 사용하는 경우 `manifests/gateway.yaml`에서 HTTPS 리스너를 제거하고, `values-infra.yaml`에서 TLS 설정을 주석 처리합니다.

## 4단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 다음 항목을 선택합니다.

1. **설치 모드**: `1` (LoadBalancer) 또는 `2` (NodePort — 권장)
2. **노드 고정**: Envoy Proxy를 배치할 특정 노드 이름 입력 (선택)
3. **전역 정책**: `manifests/policy-global.yaml` 적용 여부

## 5단계: 배포 후 네트워크 구성

배포 완료 후 설치 모드에 따라 아래 Case를 확인합니다.

### Case A: LoadBalancer — 자동 할당 완료

클라우드 환경이거나 MetalLB가 구성된 경우입니다.

```bash
kubectl get svc -n envoy-gateway-system
# EXTERNAL-IP 필드에 IP 주소가 표시되면 정상
```

별도 조치 없이 표시된 IP로 접속합니다.

### Case B: LoadBalancer — 수동 할당 필요 (온프레미스)

EXTERNAL-IP가 `<pending>` 상태로 멈춰 있는 경우입니다.

> DaemonSet + `externalTrafficPolicy: Local` 구성이라면 전체 워커 노드 IP를 등록해야 합니다.
> 앞단에 L4 장비(VIP)가 있다면 VIP 하나만 등록해도 충분합니다.

**단일 노드 IP 등록:**

```bash
SVC_NAME=$(kubectl get svc -n envoy-gateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')

kubectl patch svc -n envoy-gateway-system $SVC_NAME \
  --type merge \
  -p '{"spec":{"externalIPs":["<NODE_IP>"]}}'
```

**워커 노드 전체 IP 등록 (DaemonSet 구성):**

```bash
SVC_NAME=$(kubectl get svc -n envoy-gateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')

kubectl patch svc -n envoy-gateway-system $SVC_NAME \
  --type merge \
  -p '{"spec":{"externalIPs":["10.10.10.73","10.10.10.74","10.10.10.75"]}}'
```

1분 이상 Gateway가 false 상태로 남아 있으면 수동으로 주소를 바인딩합니다.

**단일 IP:**

```bash
kubectl patch gateway cmp-gateway -n envoy-gateway-system \
  --type='merge' \
  -p '{"spec":{"addresses":[{"type":"IPAddress","value":"<NODE_IP>"}]}}'
```

**여러 IP (DaemonSet 구성):**

```bash
kubectl patch gateway cmp-gateway -n envoy-gateway-system \
  --type='merge' \
  -p '{
    "spec":{
      "addresses":[
        {"type":"IPAddress","value":"10.10.10.73"},
        {"type":"IPAddress","value":"10.10.10.74"},
        {"type":"IPAddress","value":"10.10.10.75"}
      ]
    }
  }'
```

### Case C: NodePort — VIP(HAProxy) 연동

NodePort 모드 설치 시 HTTP 30080, HTTPS 30443 포트로 고정됩니다.

```bash
kubectl get svc -n envoy-gateway-system
# 출력 확인: 80:30080/TCP, 443:30443/TCP
```

**L4 스위치(Hardware LB) 연동 시:**

네트워크 담당자에게 워커 노드 IP와 고정 포트(30080, 30443)를 L4 장비의 Real Server로 등록 요청합니다.
사용자는 L4 장비의 VIP(80/443)로 접속합니다.

트래픽 흐름:

```text
Client → VIP(L4) → Worker Node IP:30080/30443 → Envoy → Backend
```

**L4 장비 없는 경우 (Keepalived + HAProxy):**

워커 노드에 Keepalived(VIP 관리) + HAProxy(포트 포워딩)를 구성합니다.

```bash
# HAProxy 설정 예시 (/etc/haproxy/haproxy.cfg)
# VIP: 10.10.10.200, 워커 노드: 10.10.10.73~75
frontend envoy-http
    bind 10.10.10.200:80
    mode tcp
    default_backend envoy-workers-http

backend envoy-workers-http
    mode tcp
    balance roundrobin
    server worker1 10.10.10.73:30080 check
    server worker2 10.10.10.74:30080 check
    server worker3 10.10.10.75:30080 check

frontend envoy-https
    bind 10.10.10.200:443
    mode tcp
    default_backend envoy-workers-https

backend envoy-workers-https
    mode tcp
    balance roundrobin
    server worker1 10.10.10.73:30443 check
    server worker2 10.10.10.74:30443 check
    server worker3 10.10.10.75:30443 check
```

**L4 없이 단일 노드 직접 접속:**

```text
HTTP  : http://<NODE_IP>:30080
HTTPS : https://<NODE_IP>:30443
```

방화벽에서 30080, 30443 포트가 허용되어야 합니다.

## 6단계: 서비스 노출 (HTTPRoute)

신규 서비스를 Envoy를 통해 노출하려면 HTTPRoute 리소스를 생성합니다.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: default
spec:
  parentRefs:
    - name: cmp-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "my-app.devops.internal"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app-service
          port: 80
```

## 7단계: HTTPRoute 트러블슈팅

### 503 / Connection Refused — 백엔드 포트 불일치

Envoy는 Service ClusterIP 포트가 아닌 **Pod의 실제 컨테이너 포트**로 연결을 시도합니다.

```bash
# 파드가 실제로 열고 있는 포트 확인
kubectl get pod <POD_NAME> -n <NAMESPACE> -o yaml | grep containerPort
```

확인한 포트로 HTTPRoute의 `backendRefs.port`를 수정합니다.

```bash
kubectl patch httproute <ROUTE_NAME> -n <NAMESPACE> --type='json' \
  -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":8080}]'
```

### 404 — URL Rewrite 필요

앱이 하위 경로(Context Path)를 인식하지 못해 404가 발생하는 경우 URLRewrite 필터를 적용합니다.

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /myapp
    filters:
      - type: URLRewrite
        urlRewrite:
          path:
            type: ReplacePrefixMatch
            replacePrefixMatch: /
    backendRefs:
      - name: my-app-service
        port: 8080
```

### Gateway 연결 상태 확인

```bash
# Gateway 상태 (attachedRoutes 수, Programmed 상태 확인)
kubectl get gateway cmp-gateway -n envoy-gateway-system -o yaml

# 전체 HTTPRoute 연결 상태 요약
kubectl get httproute -A

# 특정 HTTPRoute 상세 원인 조회
kubectl describe httproute <ROUTE_NAME> -n <NAMESPACE>
```

주요 실패 원인:

- `parentRefs.name`이 실제 Gateway 이름(`cmp-gateway`)과 불일치
- Gateway Listener의 `allowedRoutes.namespaces` 설정으로 해당 네임스페이스가 차단됨

## 운영 — 로그 확인

```bash
# Envoy Proxy (Data Plane) 로그 — 실제 트래픽, 접속 오류 확인
kubectl logs -n envoy-gateway-system -f \
  -l gateway.envoyproxy.io/owning-gateway-name=cmp-gateway

# Gateway Controller (Control Plane) 로그 — 설정 변환, 배포 실패 원인 확인
kubectl logs -n envoy-gateway-system -f \
  -l app.kubernetes.io/name=envoy-gateway
```

## (심화) 와일드카드 TLS 인증서 적용

`*.devops.internal` 와일드카드 인증서 하나로 모든 서브도메인의 HTTPS를 통합 관리합니다.

### 1단계: Secret 생성

```bash
kubectl create secret tls wildcard-tls-secret \
  --cert=fullchain.pem \
  --key=privkey.pem \
  -n envoy-gateway-system
```

### 2단계: Gateway 리스너 설정

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cmp-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg-cluster-entry
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.devops.internal"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-tls-secret
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
```

### 3단계: HTTPRoute 추가

와일드카드 범위 내 도메인이라면 HTTPRoute만 추가하면 자동으로 HTTPS가 적용됩니다. Secret을 새로 만들 필요가 없습니다.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nexus-route
  namespace: nexus
spec:
  parentRefs:
    - name: cmp-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "nexus.devops.internal"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: nexus-nexus-repository-manager
          port: 8081
```

### 검증

```bash
# SSL Handshake 및 인증서 확인
curl -v https://nexus.devops.internal \
  --resolve nexus.devops.internal:443:<GATEWAY_IP>
```

성공 기준: `Server certificate:` 항목에 `CN=*.devops.internal` 확인, 연결 성공.

## 삭제

```bash
./scripts/uninstall.sh
```
