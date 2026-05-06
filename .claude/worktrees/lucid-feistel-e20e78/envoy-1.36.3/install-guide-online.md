# Envoy Gateway v1.6.1 / Proxy v1.36.3 온라인 설치 가이드

인터넷이 가능한 환경에서 Envoy Gateway 를 Kubernetes 클러스터에 설치하는 절차입니다.
폐쇄망 절차는 [install-guide.md](install-guide.md) 를 참고하세요.

## 전제 조건

- Kubernetes 클러스터 구성 완료 (v1.30+ 권장)
- Helm v3.14.0 이상 설치 완료
- `kubectl` CLI 사용 가능
- 외부 저장소 접근 가능 (`docker.io` Helm OCI 레지스트리)
- Cilium 사용 시 `gatewayAPI.enabled=false` 로 설치되어 있어야 함 (GatewayClass 충돌 방지)

## 아키텍처 개요

- **Network:** `hostNetwork: false`
- **Service:** `type: LoadBalancer` 또는 `type: NodePort`
- **트래픽 흐름 (LoadBalancer):**

  ```text
  Client → External IP (LB) → Service (80/443) → Envoy Pod → Backend Pod
  ```

- **트래픽 흐름 (NodePort + VIP):**

  ```text
  Client → VIP (HAProxy) → Worker Node IP:30080/30443 → Envoy Pod → Backend Pod
  ```

---

## 1단계: Gateway API CRD 설치

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 확인
kubectl get crd | grep gateway.networking.k8s.io
```

> Cilium 등 다른 구현체가 이미 설치한 상태라면 이 단계 생략.

---

## 2단계: Envoy Gateway Helm 차트 다운로드 (선택, values 검토용)

```bash
helm pull oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.1 \
  --untar --untardir /tmp/eg

ls /tmp/eg/gateway-helm/   # values.yaml 등 확인
```

> 본 레포의 `charts/gateway-1.6.1` 와 동일 버전입니다.

---

## 3단계: TLS 사전 구성 (HTTPS 사용 시)

HTTPS 를 사용할 경우 Helm 배포 전에 Gateway 네임스페이스에 TLS Secret 을 생성합니다.

```bash
# 네임스페이스 생성
kubectl create ns envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f -

# TLS Secret 생성
kubectl create secret tls gateway-tls \
  --cert=cert.pem --key=key.pem \
  -n envoy-gateway-system
```

추가 인증서가 있으면 Secret 을 각각 생성한 뒤 `manifests/gateway.yaml` 의 `listeners` 항목에 추가.

HTTP 만 쓸 거면 `values-infra.yaml` 의 HTTPS 리스너 / TLS 설정을 주석 처리합니다.

---

## 4단계: 컨트롤 플레인 설치 (Envoy Gateway)

```bash
# OCI 차트 직접 설치
helm upgrade --install eg-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.1 \
  -n envoy-gateway-system

# 상태 확인
kubectl -n envoy-gateway-system get pods
kubectl get gatewayclass    # eg (Accepted=True) 확인
```

---

## 5단계: 데이터 플레인 (Gateway 인스턴스) 배포

본 레포의 `charts/gateway-infra` 차트로 Gateway / HTTPRoute / 정책을 묶어 배포.

```bash
helm upgrade --install gateway-infra ./charts/gateway-infra \
  -n envoy-gateway-system \
  -f ./values-infra.yaml

# 전역 정책 (선택)
kubectl apply -f manifests/policy-global.yaml
```

---

## 6단계: 배포 후 네트워크 구성

### Case A: LoadBalancer — 자동 할당

클라우드 환경 또는 MetalLB 가 구성된 경우입니다.

```bash
kubectl get svc -n envoy-gateway-system
# EXTERNAL-IP 필드에 IP 가 표시되면 정상
```

### Case B: LoadBalancer — 수동 할당 (온프레미스)

EXTERNAL-IP 가 `<pending>` 으로 멈춰 있는 경우.

> DaemonSet + `externalTrafficPolicy: Local` 구성이면 전체 워커 노드 IP 를 등록.
> 앞단에 L4 장비(VIP)가 있다면 VIP 하나만 등록해도 충분.

```bash
SVC_NAME=$(kubectl get svc -n envoy-gateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')

# 단일 노드
kubectl patch svc -n envoy-gateway-system $SVC_NAME --type merge \
  -p '{"spec":{"externalIPs":["<NODE_IP>"]}}'

# 워커 노드 전체 (DaemonSet)
kubectl patch svc -n envoy-gateway-system $SVC_NAME --type merge \
  -p '{"spec":{"externalIPs":["10.10.10.73","10.10.10.74","10.10.10.75"]}}'
```

1분 이상 Gateway 가 False 면 주소 직접 바인딩:

```bash
kubectl patch gateway cluster-gateway -n envoy-gateway-system --type='merge' \
  -p '{"spec":{"addresses":[
    {"type":"IPAddress","value":"10.10.10.73"},
    {"type":"IPAddress","value":"10.10.10.74"},
    {"type":"IPAddress","value":"10.10.10.75"}
  ]}}'
```

### Case C: NodePort — VIP(HAProxy) 연동

NodePort 모드는 HTTP 30080 / HTTPS 30443 으로 고정.

```bash
kubectl get svc -n envoy-gateway-system
# 80:30080/TCP, 443:30443/TCP
```

L4 스위치(또는 외부 HAProxy)에 워커 노드 IP + 포트(30080/30443)를 Real Server 로 등록.

#### Keepalived + HAProxy 자체 구성 예시

```bash
# /etc/haproxy/haproxy.cfg — VIP 10.10.10.200, 워커 73~75
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

L4 없이 단일 노드 직접 접속:

```text
HTTP  : http://<NODE_IP>:30080
HTTPS : https://<NODE_IP>:30443
```

방화벽에서 30080 / 30443 포트 허용 필요.

---

## 7단계: 서비스 노출 (HTTPRoute)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: default
spec:
  parentRefs:
    - name: cluster-gateway
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

---

## 8단계: HTTPRoute 트러블슈팅

### 503 / Connection Refused — 백엔드 포트 불일치

Envoy 는 Service ClusterIP 포트가 아닌 **Pod 의 실제 컨테이너 포트**로 연결합니다.

```bash
kubectl get pod <POD_NAME> -n <NS> -o yaml | grep containerPort

kubectl patch httproute <ROUTE_NAME> -n <NS> --type='json' \
  -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":8080}]'
```

### 404 — URL Rewrite 필요

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
kubectl get gateway cluster-gateway -n envoy-gateway-system -o yaml
kubectl get httproute -A
kubectl describe httproute <ROUTE_NAME> -n <NS>
```

주요 실패 원인:

- `parentRefs.name` 이 실제 Gateway 이름(`cluster-gateway`) 과 불일치
- Gateway Listener 의 `allowedRoutes.namespaces` 설정이 해당 NS 차단

---

## 운영 — 로그 확인

```bash
# Data Plane (실제 트래픽 / 접속 오류)
kubectl logs -n envoy-gateway-system -f \
  -l gateway.envoyproxy.io/owning-gateway-name=cluster-gateway

# Control Plane (설정 변환 / 배포 실패)
kubectl logs -n envoy-gateway-system -f \
  -l app.kubernetes.io/name=envoy-gateway
```

---

## (심화) 와일드카드 TLS 인증서 적용

`*.devops.internal` 와일드카드 인증서로 모든 서브도메인 HTTPS 통합 관리.

```bash
kubectl create secret tls wildcard-tls-secret \
  --cert=fullchain.pem --key=privkey.pem \
  -n envoy-gateway-system
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cluster-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg-cluster-entry
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
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
        namespaces: { from: All }
```

검증:

```bash
curl -v https://nexus.devops.internal \
  --resolve nexus.devops.internal:443:<GATEWAY_IP>
# Server certificate: CN=*.devops.internal 확인
```

---

## CVE 패치 / Minor 업그레이드

```bash
# 사용 가능 버전 확인
helm search repo oci://docker.io/envoyproxy/gateway-helm --versions | head -10

# 동일 라인 patch 업그레이드 (rolling)
helm upgrade eg-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.1 -n envoy-gateway-system \
  --reuse-values
```

Major / minor 업그레이드는 CRD 변경 동반 — release notes 우선 확인.

---

## 삭제

```bash
helm uninstall gateway-infra -n envoy-gateway-system
helm uninstall eg-gateway -n envoy-gateway-system
kubectl delete ns envoy-gateway-system

# Gateway API CRD 도 삭제 (선택)
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```
