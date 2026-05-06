# Envoy Gateway 운영 전환 체크리스트

## 배경 개념 정리

### SLB (Server Load Balancer)

클라이언트 요청을 여러 서버에 분산시켜주는 장비입니다.
이번 구성에서는 VIP로 들어온 요청을 워커 노드 여러 대에 나눠줍니다.

```text
Client → VIP(SLB) → Worker Node:30080 → Envoy → 서비스
```

### SNAT vs DSR

SLB가 트래픽을 워커 노드로 전달하는 방식입니다.

| 방식 | 설명 | 클라이언트 실IP 보존 |
| :--- | :--- | :--- |
| **SNAT** | SLB가 출발지 IP를 자신의 IP로 바꿔서 전달 | ❌ Envoy에 SLB IP만 보임 |
| **DSR** | 패킷을 그대로 워커 노드에 전달 | ✅ Envoy에 클라이언트 IP 그대로 보임 |

> 네트워크 담당자에게 "SLB가 SNAT 방식인가요, DSR 방식인가요?" 라고 물어보면 됩니다.

### PROXY Protocol (PP)

SNAT 방식에서 원래 클라이언트 IP를 잃지 않으려고 사용하는 기술입니다.
SLB가 패킷 앞에 `"원래 출발지는 1.2.3.4였어"` 라는 정보를 붙여서 보내는 방식입니다.
하드웨어 SLB는 이 기능을 지원하지 않는 경우가 많습니다.

현재 Envoy 설정에는 PP를 필수로 받도록 되어 있습니다.
SLB가 PP를 보내지 않으면 Envoy가 연결을 즉시 끊습니다.

---

## 운영 환경 전환 절차

### 1단계 — 워커 노드 NodePort 개방 확인

NodePort는 iptables 규칙으로 동작하기 때문에 `ss`나 `netstat`으로는 보이지 않습니다.
아래 명령으로 TCP 연결 가능 여부를 직접 확인합니다.

```bash
# 워커 노드 IP와 NodePort로 TCP 연결 확인
nc -zv <WORKER_NODE_IP> 30080
nc -zv <WORKER_NODE_IP> 30443

# 또는 iptables 규칙 확인
sudo iptables -t nat -nL | grep 30080
```

성공 시 출력 예시:

```text
Connection to <WORKER_NODE_IP> 30080 port [tcp/*] succeeded!
```

### 2단계 — SLB 담당자에게 확인할 것

아래 내용을 네트워크 팀에 문의합니다.

- [ ] VIP → Worker NodePort 라우팅 설정 완료 여부
  - VIP: `<VIP_IP>`
  - 포트: `30080` (HTTP), `30443` (HTTPS)
  - 대상 워커 노드 IP 및 포트 등록 완료 여부
- [ ] SLB 방식: **SNAT인지 DSR인지** 확인
- [ ] SLB가 **PROXY Protocol 송신을 지원하고 설정했는지** 확인
- [ ] Health Check 방식 확인 (TCP 체크인지, HTTP 체크인지)

### 3단계 — PP 설정 결정

2단계 확인 결과에 따라 아래 중 하나를 선택합니다.

**SLB가 PP를 보내지 않는 경우 (일반적인 하드웨어 SLB):**

```bash
# PP 정책 삭제 — 이 명령 실행 전까지는 연결이 안 됨
kubectl delete clienttrafficpolicy enable-proxy-protocol -n envoy-gateway-system
```

**SLB가 PP를 보내는 경우:**

삭제하지 않아도 됩니다. 그대로 유지합니다.

### 4단계 — Gateway 주소를 VIP로 변경

```bash
kubectl patch gateway cluster-gateway -n envoy-gateway-system \
  --type='merge' \
  -p '{"spec":{"addresses":[{"type":"IPAddress","value":"<VIP_IP>"}]}}'
```

### 5단계 — 상태 확인

```bash
# Gateway ADDRESS가 VIP로 바뀌었는지 확인
kubectl get gateway cluster-gateway -n envoy-gateway-system

# Envoy 서비스가 NodePort 30080/30443인지 확인
kubectl get svc -n envoy-gateway-system

# HTTPRoute 연결 상태 확인
kubectl get httproute -A
```

### 6단계 — 접속 테스트

DNS 또는 hosts에 도메인이 VIP로 등록된 상태에서 테스트합니다.

```bash
# HTTP 응답 코드 확인 (200 또는 302면 정상)
curl -s -o /dev/null -w "%{http_code}\n" https://<DOMAIN>/
```

---

## 클라이언트 실IP 보존 현황

| SLB 방식 | PP 지원 | Envoy에서 보이는 클라이언트 IP |
| :--- | :--- | :--- |
| DSR | 불필요 | 실제 클라이언트 IP |
| SNAT + PP 송신 | 지원 | 실제 클라이언트 IP |
| SNAT + PP 미지원 | 미지원 | SLB IP (실IP 보존 불가) |

SNAT + PP 미지원 환경에서 실IP가 필요하다면 네트워크 팀과 별도 협의가 필요합니다.

---

## 롤백 방법

문제가 생겼을 때 원래 상태(externalIPs 방식)로 되돌리는 방법입니다.

```bash
# 1. Gateway 주소를 워커 노드 IP로 되돌리기
kubectl patch gateway cluster-gateway -n envoy-gateway-system \
  --type='merge' \
  -p '{"spec":{"addresses":[{"type":"IPAddress","value":"<WORKER_NODE_IP>"}]}}'

# 2. PP 정책을 삭제했다면 재생성
kubectl apply -f - <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: enable-proxy-protocol
  namespace: envoy-gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: cluster-gateway
  enableProxyProtocol: true
EOF
```
