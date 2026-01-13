# 📝 GitLab v18.7 System Infrastructure Specification (Air-gapped)

본 문서는 **Rocky Linux 9.6** 기반의 폐쇄망 Kubernetes 클러스터에 배포된 **GitLab Enterprise Edition v18.7**의 구성 및 운영 명세를 정의합니다.

## 1. 시스템 버전 및 환경 (Versions)

| 항목 | 사양 | 비고 |
| --- | --- | --- |
| **GitLab Version** | **18.7** | 핵심 애플리케이션 (EE) |
| **Git Engine** | **2.47.3** | Rocky Linux 9.6 환경 최적화 |
| **Storage Class** | **manual** | 정적 PV 할당 방식 |
| **OS Environment** | **Rocky Linux 9.6** | 클러스터 호스트 OS |

---

## 2. 스토리지 및 데이터 보존 (Storage & Data)

모든 데이터는 `Retain` 정책을 가진 PV에 저장되어, 서비스 삭제 시에도 데이터가 보호됩니다.

### 💾 영구 볼륨 명세 (PV/PVC)

| PVC Name | PV Name | Capacity | Usage |
| --- | --- | --- | --- |
| `repo-data-gitlab-gitaly-0` | `gitlab-gitaly-pv` | **50Gi** | Git 리포지토리 데이터 (**핵심**) |
| `data-gitlab-postgresql-0` | `gitlab-postgresql-pv` | 10Gi | 사용자/프로젝트 메타데이터 DB |
| `gitlab-minio` | `gitlab-minio-pv` | 10Gi | LFS, 빌드 아티팩트 저장소 |
| `redis-data-gitlab-redis-master-0` | `gitlab-redis-pv` | 10Gi | 세션 및 백그라운드 작업 큐 |

---

## 3. 핵심 보안 및 설정 정보 (Secrets & Config)

폐쇄망 환경 복구 시 반드시 백업이 필요한 리소스들입니다.

### 🔐 주요 보안 정보 (Secrets)

* **관리자 암호**: `gitlab-gitlab-initial-root-password` (초기 root 비번)
* **인증 키**: `gitlab-gitlab-shell-host-keys`, `gitlab-gitlab-shell-secret` (SSH 통신용)
* **DB 암호**: `gitlab-postgresql-password`, `gitlab-redis-secret`
* **Registry**: `gitlab-registry-secret`, `gitlab-registry-httpsecret` (컨테이너 이미지 인증)

### ⚙️ 서비스 설정 (ConfigMaps)

* 서비스별 `config.toml` 및 환경 설정 파일들이 `gitlab-webservice`, `gitlab-sidekiq`, `gitlab-gitaly` 등의 이름으로 관리되고 있습니다.

---

## 4. 워크로드 아키텍처 (Workloads)

### 🔹 애플리케이션 레이어 (Stateless)

* **Web/API**: `gitlab-webservice-default` (2 Replicas, HPA 적용)
* **Git SSH**: `gitlab-gitlab-shell` (2 Replicas, Git 2.47.3 기반)
* **Background**: `gitlab-sidekiq-all-in-1-v2` (비동기 워커)
* **Cloud Native**: `gitlab-kas` (Kubernetes Agent Server)

### 🔹 데이터 레이어 (Stateful)

* **Gitaly**: Git 저장소 엔진 (StatefulSet)
* **PostgreSQL**: 관계형 데이터베이스
* **Redis**: 캐시 및 메시지 브로커

---

## 5. 네트워크 통신 명세 (Network)

| Service Name | Port | Protocol | Usage |
| --- | --- | --- | --- |
| `gitlab-webservice-default` | 8080/8181 | TCP | 내부 웹 통신 및 API |
| `gitlab-gitlab-shell` | 22 | TCP | SSH 기반 Git Push/Pull |
| `gitlab-registry` | 5000 | TCP | 내부 컨테이너 이미지 레지스트리 |
| `gitlab-minio-svc` | 9000 | TCP | S3 호환 객체 스토리지 접근 |

---

## 6. 폐쇄망 운영 및 유지보수 가이드

### ✅ 장애 복구 프로세스

1. 클러스터 장애 시 `manual` 스토리지 클래스로 정의된 **물리 경로의 데이터를 보호**하십시오.
2. `gitlab-gitlab-initial-root-password` Secret을 통해 초기 관리자 권한을 확보하십시오.
3. 배포 시 `gitlab-migrations` 및 `gitlab-minio-create-buckets` Job의 성공 여부를 반드시 확인하십시오.

### ✅ 이미지 관리 (GitLab 18.7)

* 모든 이미지는 외부 인터넷이 차단되어 있으므로, 업데이트 시 내부 레지스트리에 `v18.7` 태그를 가진 이미지가 모두 존재해야 합니다.
