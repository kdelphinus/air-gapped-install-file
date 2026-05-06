# Envoy Gateway v1.7.2 / Proxy v1.37.2 온라인 설치 가이드

인터넷이 가능한 환경에서 Envoy Gateway 를 Kubernetes 클러스터에 설치하는 절차입니다.
폐쇄망 절차는 [install-guide.md](install-guide.md) 를 참고하세요.

## 전제 조건

- Kubernetes 클러스터 구성 완료 (v1.30+ 권장)
- Helm v3.14.0 이상 설치 완료
- `kubectl` CLI 사용 가능
- 외부 저장소 접근 가능 (`docker.io`, `gateway.envoyproxy.io` Helm 저장소)
- Cilium 사용 시 `gatewayAPI.enabled=false` 로 설치되어 있어야 함 (GatewayClass 충돌 방지)

## 아키텍처 개요

- **Network:** `hostNetwork: false`
- **트래픽 진입점:** `LoadBalancer` (MetalLB / 클라우드 LB) 또는 `NodePort`
- **구성 요소:**
  - **Control Plane:** Envoy Gateway v1.7.2 (`envoy-gateway-system` 네임스페이스)
  - **Data Plane:** Envoy Proxy v1.37.2 (Distroless)

| 모드 | 권장 환경 | 비고 |
| :--- | :--- | :--- |
| LoadBalancer + DaemonSet | 클라우드 / MetalLB | `externalTrafficPolicy: Local` 로 실 IP 보존 |
| NodePort + DaemonSet | L4 스위치 / HAProxy 연동 | 30080 / 30443 고정 |

---

## 1단계: Gateway API CRD 설치

Envoy Gateway 는 Gateway API CRD 가 클러스터에 존재해야 동작합니다.
(Cilium 등 다른 구현체가 이미 설치한 상태라면 이 단계 생략 가능)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 확인
kubectl get crd | grep gateway.networking.k8s.io
```

---

## 2단계: Envoy Gateway Helm 차트 등록

Envoy Gateway 는 OCI 레지스트리(`docker.io/envoyproxy/gateway-helm`)에서 제공됩니다.

```bash
# Helm 차트 풀 (선택 — values 검토용)
helm pull oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.2 \
  --untar --untardir /tmp/eg

ls /tmp/eg/gateway-helm/   # values.yaml 등 확인
```

> 본 레포의 `charts/gateway-1.7.2` 와 동일 버전입니다. 값 커스터마이징이 필요하면 위
> 풀받은 디렉터리의 `values.yaml` 을 복사해서 수정하세요.

---

## 3단계: 컨트롤 플레인 설치 (Envoy Gateway)

```bash
# 네임스페이스 생성
kubectl create ns envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f -

# OCI 차트 직접 설치 (기본값으로)
helm upgrade --install eg-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.2 \
  -n envoy-gateway-system

# 또는 본 레포의 values.yaml 활용
helm upgrade --install eg-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.2 \
  -n envoy-gateway-system \
  -f ./values.yaml
```

설치 확인:

```bash
kubectl -n envoy-gateway-system get pods
kubectl -n envoy-gateway-system get gatewayclass
# eg (Accepted=True) 출력 확인
```

---

## 4단계: 데이터 플레인 (Gateway 인스턴스) 배포

본 레포는 `charts/gateway-infra` 라는 별도 차트로 Gateway 리소스 + 라우팅 + 정책을 묶어 배포합니다.

```bash
helm upgrade --install gateway-infra ./charts/gateway-infra \
  -n envoy-gateway-system \
  -f ./values-infra.yaml

# 전역 정책 (선택)
kubectl apply -f manifests/policy-global-config.yaml
```

> Envoy Gateway 만 띄우고 본인이 직접 `Gateway` / `HTTPRoute` 를 작성할 거면 이 단계는 건너뛰고
> 5단계로 바로 가도 됩니다.

---

## 5단계: 배포 후 네트워크 구성

### LoadBalancer — 자동 할당 (MetalLB / 클라우드)

```bash
kubectl get svc -n envoy-gateway-system
# EXTERNAL-IP 가 표시되면 정상
```

### LoadBalancer — 수동 IP 할당 (온프레미스 + DaemonSet)

전체 워커 노드 IP 를 `externalIPs` 에 등록하여 고가용성을 확보합니다.

```bash
# 서비스 이름 확인
SVC_NAME=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=cluster-gateway \
  -o jsonpath='{.items[0].metadata.name}')

# 워커 노드 IP 일괄 등록
kubectl patch svc -n envoy-gateway-system $SVC_NAME --type merge \
  -p '{"spec":{"externalIPs":["<WORKER1_IP>","<WORKER2_IP>","<WORKER3_IP>"]}}'

# Gateway 가 1분 이상 False 이면 주소 직접 바인딩
kubectl patch gateway cluster-gateway -n envoy-gateway-system --type='merge' \
  -p '{"spec":{"addresses":[
    {"type":"IPAddress","value":"<WORKER1_IP>"},
    {"type":"IPAddress","value":"<WORKER2_IP>"},
    {"type":"IPAddress","value":"<WORKER3_IP>"}
  ]}}'
```

### NodePort

```bash
kubectl get svc -n envoy-gateway-system
# 80:30080/TCP, 443:30443/TCP 확인
```

L4 스위치 또는 HAProxy 의 Real Server 로 워커 IP:30080 / :30443 등록.

### 와일드카드 TLS 인증서 적용

```bash
kubectl create secret tls wildcard-tls-secret \
  --cert=fullchain.pem --key=privkey.pem \
  -n envoy-gateway-system
```

`Gateway` 리스너에 추가:

```yaml
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

## 6단계: 서비스 노출 (HTTPRoute)

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

검증:

```bash
kubectl get httproute -A
kubectl describe httproute example-service
# Conditions.Accepted=True / ResolvedRefs=True 확인
```

---

## 7단계: 운영 — 로그 확인

```bash
# Data Plane (Envoy Proxy) 로그
kubectl logs -n envoy-gateway-system -f \
  -l gateway.envoyproxy.io/owning-gateway-name=cluster-gateway

# Control Plane (Envoy Gateway) 로그
kubectl logs -n envoy-gateway-system -f \
  -l app.kubernetes.io/name=envoy-gateway
```

---

## CVE 패치 / Minor 업그레이드

Envoy Gateway 차트 업그레이드만으로 patch 가 적용됩니다 (rolling).

```bash
# 차트 버전 확인
helm search repo oci://docker.io/envoyproxy/gateway-helm --versions | head -10

# 동일 라인 patch 업그레이드
helm upgrade eg-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.2 -n envoy-gateway-system \
  --reuse-values
```

> Major / minor 업그레이드(예: 1.6 → 1.7)는 CRD 변경이 동반되므로
> [Envoy Gateway Release Notes](https://gateway.envoyproxy.io/docs/news/releases/) 를 먼저 확인하세요.

---

## 삭제

```bash
helm uninstall gateway-infra -n envoy-gateway-system
helm uninstall eg-gateway -n envoy-gateway-system
kubectl delete ns envoy-gateway-system

# (선택) Gateway API CRD 도 함께 삭제
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```
