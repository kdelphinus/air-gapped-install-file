# 📝 Ingress-Nginx Controller Specification (HostNetwork Mode)

본 문서는 **Ingress-Nginx v4.10.1**을 기반으로, 호스트 네트워크에 직접 바인딩되어 동작하는 L7 라우팅 시스템 명세를 정의합니다.

## 1. 시스템 개요 (System Overview)

이 구성은 성능 최적화를 위해 Kubernetes의 가상 네트워크(플라넬, 캘리코 등)를 거치지 않고, **물리 노드의 80/443 포트를 직접 점유**하여 동작합니다.

| 항목 | 사양 | 비고 |
| --- | --- | --- |
| **Controller Version** | **v4.10.1** | 안정화 버전 |
| **Network Mode** | **HostNetwork: True** | 노드 물리 네트워크 직접 사용 |
| **Service Type** | NodePort / LoadBalancer | 엔드포인트 노출용 |
| **진입점 포트** | **80(HTTP), 443(HTTPS)** | 호스트 노드 IP로 직접 접속 |

---

## 2. 워크로드 및 네트워크 명세 (Workloads)

### 🚀 컨트롤러 구성

- **Deployment**: `ingress-nginx-controller` (HostNetwork 활성)
- **특이사항**: `pod/ingress-nginx-controller-랜덤값` 이 실행 중인 노드의 IP가 곧 전체 서비스의 진입점이 됩니다.
- **Admission Webhook**: 리소스 생성 시 유효성을 검사하는 `ingress-nginx-controller-admission` 서비스가 ClusterIP로 별도 운영됩니다.

### 🌐 포트 맵핑 현황

| 프로토콜 | 호스트 포트 | 서비스 포트 (NodePort) | 용도 |
| --- | --- | --- | --- |
| **HTTP** | **80** | 30007 | 일반 웹 트래픽 진입점 |
| **HTTPS** | **443** | 32647 | 보안 웹 트래픽 (SSL/TLS 종료) |

---

## 3. 스토리지 현황 (Cluster Data Context)

`ingress-nginx` 환경에서 함께 조회된 클러스터 전체 PV 자원입니다. 대규모 운영 흔적이 보이는 `Retain` 정책의 볼륨들이 다수 존재합니다.

| PV Name | Capacity | Reclaim Policy | Status |
| --- | --- | --- | --- |
| `elasticsearch-pv` | 50Gi | Retain | **Bound** (로그 수집용) |
| `kafka-pv` | 10Gi | Retain | **Bound** (메시징 큐) |
| `jenkins-pv-volume` | 10Gi | Retain | **Released** (이전 데이터 보존 중) |
| `grafana-pv-on-demo-02~07` | 각 20Gi | Retain | **Available** (확장용 로컬 스토리지) |

---

## 4. 핵심 설정 및 보안 (Security & Config)

### 🔐 보안 정보 (Secrets)

* **ingress-nginx-admission**: 컨트롤러와 API 서버 간의 보안 통신용 인증서.
* **default-token**: 서비스 어카운트 권한 관리를 위한 토큰.

### ⚙️ 시스템 설정 (ConfigMaps)

- **ingress-nginx-controller (12 Data 항목)**:
- `use-forwarded-headers: "true"` (HostNetwork 사용 시 필수 설정)
- `compute-full-forwarded-for: "true"` (실제 클라이언트 IP 확보용)
- 기타 타임아웃 및 버퍼 사이즈 튜닝 값 포함.

---

## 5. 폐쇄망 운영 가이드 (HostNetwork 전용)

### ✅ 클라이언트 IP 보존 (Source IP Preservation)

HostNetwork 방식을 사용하면 `ExternalTrafficPolicy: Local` 설정 없이도 클라이언트의 실제 IP를 Nginx 로그에서 바로 확인할 수 있습니다. 이는 폐쇄망 내 보안 감사 시 매우 유리합니다.

### ✅ 노드 포트 충돌 주의

- 노드에서 직접 80, 443 포트를 점유하므로, **해당 노드에 다른 웹 서버(Apache, 다른 Nginx 등)가 실행 중이지 않아야 합니다.**
- 포트 변경이 필요할 경우 `deployment`의 `containerPort`와 `hostPort` 설정을 함께 수정해야 합니다.
