# 클라이언트 IP 보존 — 현황 및 적용 TODO

## 현재 상황 요약

### 문제

- Envoy Gateway가 `LoadBalancer` + `externalIPs`(노드 IP 수동 패치) 방식으로 배포됨
- `externalTrafficPolicy: Local`을 설정해도 `externalIPs`는 이를 무시하고 SNAT 발생
- 결과: 백엔드 앱에 클라이언트 IP 대신 노드 IP가 찍힘

### 근본 원인

`externalIPs`는 kube-proxy의 `KUBE-EXTERNAL-IP` chain을 사용하며
`externalTrafficPolicy`가 적용되지 않는다.

### 해결 방향

HAProxy를 앞단에 두고 PROXY Protocol로 실제 클라이언트 IP를 전달한다.

```text
클라이언트 → HAProxy(80/443) --[PROXY Protocol]-→ Envoy NodePort(30080/30443) → Backend
```

로컬 k3s 환경에서 검증 완료. PROXY Protocol 미적용 시 NodePort 직접 접근이
차단되는 것까지 확인.

---

## TODO: 운영 환경 적용

### 사전 확인

```bash
# 현재 서비스 상태 확인
kubectl get svc -n envoy-gateway-system

# externalIPs 수동 패치 여부 확인
kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[*].spec.externalIPs}'

# 현재 ClientTrafficPolicy 확인
kubectl get clienttrafficpolicy -n envoy-gateway-system
kubectl describe clienttrafficpolicy -n envoy-gateway-system
```

### Step 1: externalIPs 수동 패치 제거

기존에 수동으로 박아넣은 `externalIPs`를 먼저 제거합니다.
(helm upgrade가 덮어쓰지 못할 수 있어 미리 제거)

```bash
SVC_NAME=$(kubectl get svc -n envoy-gateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')

kubectl patch svc -n envoy-gateway-system $SVC_NAME \
  --type merge \
  -p '{"spec":{"externalIPs":[]}}'
```

### Step 2: Helm upgrade (NodePort + PROXY Protocol 활성화)

```bash
cd <envoy-1.36.3 경로>/

helm upgrade gateway-infra ./gateway-infra \
  -n envoy-gateway-system \
  -f gateway-infra/nodeport-values.yaml
```

적용되는 변경사항:

- `service.type: NodePort`
- `service.trafficPolicy: Local`
- `clientIP.proxyProtocol: true` → `ClientTrafficPolicy(enable-proxy-protocol)` 생성

### Step 3: NodePort 번호 확인

```bash
kubectl get svc -n envoy-gateway-system
# 예시: 80:30080/TCP, 443:30443/TCP
```

NodePort가 30080/30443이 아닌 경우 HAProxy 설정의 포트를 맞춰 수정합니다.

### Step 4: HAProxy 설정 적용

`haproxy-proxy-protocol.cfg`를 참고해 `/etc/haproxy/haproxy.cfg`에 추가합니다.

- `<NODE_IP>` → 실제 Kubernetes 노드 IP로 교체
- NodePort 번호 → Step 3에서 확인한 값으로 교체

```bash
# 문법 검증
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# 적용
sudo systemctl reload haproxy
```

keepalived VIP 환경이라면 모든 마스터 노드에 동일하게 적용합니다.

### Step 5: hosts 파일 / DNS 업데이트

기존 hosts 파일에 externalIPs(노드 IP)로 등록된 도메인이 있다면,
HAProxy 노드 IP(또는 VIP)로 변경합니다.

```text
# 기존
<노드-IP>  domain.example.com

# 변경 후
<HAProxy-노드-IP 또는 VIP>  domain.example.com
```

---

## 검증

### 클라이언트 IP 확인

HAProxy를 통해 요청 시 `X-Forwarded-For`에 실제 클라이언트 IP가 찍혀야 합니다.

```bash
curl -H "Host: <도메인>" http://<HAProxy-IP>/
```

### NodePort 직접 접근 차단 확인

PROXY Protocol 헤더 없이 NodePort에 직접 접근 시 차단되면 정상입니다.

```bash
curl --max-time 3 http://<노드-IP>:30080/
# timeout 또는 connection reset → 정상
```

### ClientTrafficPolicy 상태 확인

```bash
kubectl describe clienttrafficpolicy enable-proxy-protocol -n envoy-gateway-system
# Conditions.Status: True 확인
```

---

## 롤백 방법

적용 후 문제가 생겼을 때 되돌리는 방법입니다.

```bash
# PROXY Protocol 비활성화 + LoadBalancer 복원
helm upgrade gateway-infra ./gateway-infra \
  -n envoy-gateway-system

# externalIPs 재패치 (필요 시)
SVC_NAME=$(kubectl get svc -n envoy-gateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')

kubectl patch svc -n envoy-gateway-system $SVC_NAME \
  --type merge \
  -p '{"spec":{"externalIPs":["<노드-IP>"]}}'
```

---

## 관련 파일

| 파일 | 설명 |
| :--- | :--- |
| `gateway-infra/nodeport-values.yaml` | NodePort + PROXY Protocol 활성화 values |
| `gateway-infra/values.yaml` | 기본 values (`clientIP.proxyProtocol: false`) |
| `gateway-infra/templates/main.yaml` | ClientTrafficPolicy 조건부 포함 |
| `haproxy-proxy-protocol.cfg` | HAProxy 샘플 설정 |
| `client-ip-preservation.md` | 상세 구성 가이드 |
