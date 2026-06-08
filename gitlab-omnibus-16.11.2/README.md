# 📝 GitLab Omnibus Infrastructure Specification

본 문서는 **GitLab EE 16.11.2-ee.0** Omnibus 패키지를 기반으로 구축된 단일 파드 올인원(All-in-One) 인프라 명세를 정의합니다.

## 1. 시스템 버전 정보 (Version Specification)

폐쇄망 환경의 안정적인 운영을 위해 검증된 Omnibus 패키지 버전을 사용합니다.

| 항목 | 버전 | 비고 |
| --- | --- | --- |
| **GitLab EE** | **16.11.2-ee.0** | Omnibus 올인원 이미지 |
| **PostgreSQL** | **14.x** | GitLab 내장 DB |
| **Redis** | **7.x** | GitLab 내장 캐시 |

---

## 2. 서비스 아키텍처 (Architecture)

### 🔹 Omnibus Single Pod
- **특징**: PostgreSQL, Redis, Nginx, Sidekiq, Gitaly 등 GitLab 운영에 필요한 모든 컴포넌트가 단일 파드 내에서 실행됩니다.
- **장점**: 관리가 단순하며 리소스 오버헤드가 적어 소규모 및 중규모 팀에 적합합니다.
- **네임스페이스**: `gitlab-omnibus`

---

## 3. 리소스 명세 및 네트워크 (Resources & Networking)

### 🔹 서비스 포트 맵핑 (NodePort)

| 프로토콜 | 내부 포트 | 외부 노출 포트 (NodePort) | 용도 |
| --- | --- | --- | --- |
| **HTTP** | 80 | **32135** (기본값) | 웹 인터페이스 및 Git HTTP 접근 |
| **SSH** | 22 | **30022** | Git SSH 접근 (Clone/Push) |

### 🔹 스토리지 할당 (Persistence)

| 용도 | 마운트 경로 | 권장 용량 | 설명 |
| --- | --- | --- | --- |
| **Data** | `/var/opt/gitlab` | 50Gi+ | 레포지토리, DB 데이터, LFS 등 |
| **Config** | `/etc/gitlab` | 1Gi | `gitlab.rb`, SSL 인증서 등 설정 |

---

## 4. 주요 설정 (Configuration)

- **External URL**: `http://<IP_OR_DOMAIN>:<PORT>` 형식을 지원합니다.
- **Timezone**: `Asia/Seoul` (기본값)
- **Monitoring**: 리소스 절약을 위해 Prometheus/Grafana 등 내장 모니터링은 기본적으로 비활성화되어 있습니다.
