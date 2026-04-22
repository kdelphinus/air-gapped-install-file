# 📝 Envoy Gateway Infrastructure Specification

본 문서는 **Envoy v1.37.2** 및 **Gateway API v1.4.1**을 기반으로 구축된 클러스터 진입점(Entry Point) 명세를 정의합니다.

## 1. 시스템 버전 정보 (Version Specification)

폐쇄망 환경의 보안 및 표준 준수를 위해 다음 버전이 적용되었습니다.

| 항목 | 버전 | 비고 |
| --- | --- | --- |
| **Envoy Proxy** | **v1.37.2** | 데이터 평면 (실제 트래픽 처리 엔진) |
| **Envoy Gateway** | **v1.7.2** | 제어 평면 (Envoy 설정 및 관리) |
| **Gateway API** | **v1.4.1 (Standard)** | Kubernetes 표준 Gateway API 준수 |

---

## 2. 시스템 아키텍처 및 역할 (Architecture)

### 🔹 Control Plane: `envoy-gateway` (v1.7.2)

- **역할**: `Gateway`, `HTTPRoute` 등 API 리소스를 감시하여 Envoy용 설정(xDS)으로 변환.
- **특징**: 데이터 평면과 분리되어 있어, 컨트롤러에 문제가 생겨도 이미 설정된 트래픽 처리는 중단되지 않습니다.

### 🔹 Data Plane: `cluster-gateway` (Envoy v1.37.2)

- **역할**: 실제 사용자 요청을 받아 백엔드 서비스로 라우팅.
- **구성**: `pod/envoy-envoy-gateway-system-cluster-gateway-...` (2/2 Ready)
- **Envoy Container**: 고성능 L7 프록시 실행.
- **Shutdown Manager**: 안전한 연결 종료를 위한 관리 컨테이너.

---

## 3. 리소스 명세 및 네트워크 (Resources & Networking)

### 🔹 Gateway API 리소스

- **GatewayClass**: `eg-cluster-entry` (Gateway 생성 방식 정의)
- **Gateway**: `cluster-gateway` (IP `1.1.1.198`에 바인딩된 실제 진입점)

### 🔹 서비스 포트 맵핑 (NodePort)

| 프로토콜 | 내부 포트 | 외부 노출 포트 (NodePort) | 용도 |
| --- | --- | --- | --- |
| **HTTPS** | 443 | **30443** | 보안 웹 트래픽 (SSL/TLS 종료) |
| **HTTP** | 80 | **30080** | 일반 웹 트래픽 (Redirect용) |

---

## 4. 주요 설정 및 보안 (Security & Config)

### 🔐 인증서 및 보안 (Secrets)

- `envoy-gateway`: 시스템 구성 요소 간 상호 인증(mTLS)을 위한 인증서.
- `envoy-oidc-hmac`: **Envoy v1.37.2**에서 지원하는 최신 OIDC 인증 필터용 HMAC 키.
- `envoy-rate-limit`: 서비스 안정성을 위한 트래픽 제한 정책용 TLS 정보.

### ⚙️ 시스템 설정 (ConfigMaps)

- `envoy-gateway-config`: Envoy Gateway v1.7.2의 동작 파라미터(필터 설정, 로그 관리 등) 저장.

---

## 5. 폐쇄망 운영 가이드 (Operational Guide)

### ✅ 신규 서비스 노출 절차

1. 서비스에 맞는 `HTTPRoute` 리소스 생성.
2. `parentRefs`를 `cluster-gateway`로 지정.
3. 폐쇄망 환경이므로 외부 도메인 대신 내부 DNS 또는 `/etc/hosts`에 `1.1.1.198`을 등록하여 테스트.

### ✅ 모니터링 및 트러블슈팅

- **Envoy 로그 확인**: 트래픽 라우팅 실패 시 Envoy 컨테이너의 Access Log를 확인하십시오.
- **xDS 상태**: `envoy-gateway`가 Envoy 프록시에 설정을 제대로 전달하는지 `status` 필드를 통해 확인하십시오.

---

## 6. 배포 모드 선택 (Traffic Policy & Deployment Type)

### 개요

두 가지 설정의 조합으로 트래픽 처리 방식이 결정됩니다.

| 설정 | 옵션 | 기본값 |
| --- | --- | --- |
| `service.trafficPolicy` | `Cluster` / `Local` | `Local` |
| `envoy.deploymentType` | `Deployment` / `DaemonSet` | `DaemonSet` |

### 모드 비교

| 항목 | Cluster + Deployment | Local + DaemonSet |
| --- | --- | --- |
| 클라이언트 실IP 보존 | 불가 (노드 IP로 SNAT) | 가능 |
| IP 기반 접근제어 / 감사로그 | 불가 | 가능 |
| 노드 추가 시 Pod 자동 배포 | 수동 | 자동 |
| Pod 재시작 중 트래픽 처리 | 다른 노드로 우회 | 해당 노드 일시 드롭 |
| 부하 분산 | kube-proxy가 균등 분산 | 노드 단위 분산 |
| 권장 환경 | 단일 노드 / IP 불필요 | 멀티 노드 / IP 기반 정책 필요 |

### 선택 기준

- **클라이언트 실IP가 필요하다** (접근 로그, IP 차단, rate limiting 등) → `Local + DaemonSet`
- **단순하게 동작만 되면 된다** (IP 불필요, 단일 노드) → `Cluster + Deployment`

### 적용 방법

#### 신규 설치 — Local + DaemonSet (기본값, 추가 옵션 불필요)

```bash
helm upgrade --install gateway-infra ./gateway-infra \
  -n envoy-gateway-system
```

#### 신규 설치 — Cluster + Deployment

```bash
helm upgrade --install gateway-infra ./gateway-infra \
  -n envoy-gateway-system \
  --set service.trafficPolicy=Cluster \
  --set envoy.deploymentType=Deployment
```
