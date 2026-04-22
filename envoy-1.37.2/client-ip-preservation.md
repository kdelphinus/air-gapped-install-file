# 클라이언트 IP 보존 가이드 (HAProxy + PROXY Protocol)

## 개요

Envoy Gateway NodePort 앞단에 HAProxy를 두고, PROXY Protocol로 실제
클라이언트 IP를 Envoy에 전달하는 구성입니다.

로컬 k3s 환경에서 검증 완료되었습니다.

## 배경: externalIPs 방식의 한계

아래 조합으로는 클라이언트 IP 보존이 되지 않습니다.

- Service type `LoadBalancer` + `externalIPs`(노드 IP 수동 패치)
- `externalTrafficPolicy: Local` 설정

`externalIPs`는 kube-proxy의 `KUBE-EXTERNAL-IP` chain을 사용하며
`externalTrafficPolicy: Local`이 적용되지 않아 SNAT가 항상 발생합니다.
결과적으로 Envoy Pod이 받는 소스 IP가 노드 IP로 고정됩니다.

## 트래픽 흐름

```text
클라이언트
  → HAProxy (80/443, PROXY Protocol 헤더 추가)
  → Envoy NodePort (30080/30443)
  → Envoy Pod (PROXY Protocol 헤더에서 실제 클라이언트 IP 추출)
  → Backend Pod (X-Forwarded-For에 실제 클라이언트 IP 포함)
```

TCP 레벨에서 SNAT가 발생해도 PROXY Protocol 헤더는 애플리케이션 레이어에
있으므로 영향받지 않습니다.

## 수정된 파일 목록

```text
envoy-1.37.2/
├── charts/
│   └── gateway-infra/
│       ├── values.yaml            # clientIP.proxyProtocol 항목 추가
│       └── templates/
│           └── main.yaml          # ClientTrafficPolicy 조건부 추가
```

## 적용 방법

### 1. HAProxy 설정

`/etc/haproxy/haproxy.cfg`에 설정을 추가합니다.
`<NODE_IP>` 부분을 실제 Kubernetes 노드 IP로 교체하세요.

NodePort가 기본값(30080/30443)이 아닌 경우 포트도 함께 수정합니다.

```bash
# 문법 검증
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# 적용
sudo systemctl reload haproxy
```

### 2. Helm upgrade (NodePort + PROXY Protocol 활성화)

```bash
cd envoy-1.37.2/

# values-infra.yaml에서 clientIP.proxyProtocol: true 로 수정 후 실행하거나 --set 사용
helm upgrade gateway-infra ./charts/gateway-infra \
  -n envoy-gateway-system \
  -f ./values-infra.yaml \
  --set service.type=NodePort \
  --set clientIP.proxyProtocol=true
```

### 3. NodePort 확인

```bash
kubectl get svc -n envoy-gateway-system
# 80:30080/TCP, 443:30443/TCP 확인
```

### 4. hosts 파일 설정

DNS 서버 없이 hosts 파일을 사용하는 경우, HAProxy가 떠 있는 노드 IP를
도메인에 매핑합니다.

```text
<HAProxy-노드-IP>  domain.example.com
```

## 검증

### 클라이언트 IP 확인

X-Forwarded-For 헤더에 실제 클라이언트 IP가 찍히는지 확인합니다.

```bash
curl -H "Host: <도메인>" http://<HAProxy-IP>/
```

### NodePort 직접 접근 차단 확인

`clientIP.proxyProtocol: true` 적용 후 NodePort 직접 접근은 차단됩니다.
이것이 정상입니다.

```bash
# 차단 확인 (timeout 또는 connection reset이 정상)
curl --max-time 3 http://<노드-IP>:30080/
```

### ClientTrafficPolicy 상태 확인

```bash
kubectl get clienttrafficpolicy -n envoy-gateway-system
kubectl describe clienttrafficpolicy enable-proxy-protocol -n envoy-gateway-system
```

## 주의 사항

- HAProxy는 반드시 `mode tcp`를 사용합니다.
- `clientIP.proxyProtocol: true` 적용 후 NodePort 직접 접근이 차단됩니다.
- `send-proxy-v2`는 PROXY Protocol v2(바이너리 형식)입니다.
