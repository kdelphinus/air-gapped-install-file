# GitLab v18.7 System Infrastructure Specification (Air-gapped)

본 문서는 폐쇄망 Kubernetes 클러스터에 배포된 **GitLab Enterprise Edition v18.7**의
구성 및 운영 명세를 정의합니다.

## 1. 시스템 버전 및 환경

| 항목 | 사양 |
| :--- | :--- |
| GitLab Version | 18.7 (EE) |
| Git Engine | 2.47.3 |
| OS Environment | Rocky Linux 9.6 |
| Helm Chart | gitlab/gitlab |

---

## 2. 스토리지 및 데이터 보존

모든 데이터는 `Retain` 정책을 가진 PV에 저장되어 서비스 삭제 시에도 보호됩니다.

| PVC | PV | Capacity | StorageClass | 용도 |
| :--- | :--- | :--- | :--- | :--- |
| `repo-data-gitlab-gitaly-0` | `gitlab-gitaly-pv` | 50Gi | local-path | Git 리포지토리 데이터 (핵심) |
| `data-gitlab-postgresql-0` | `gitlab-postgresql-pv` | 10Gi | local-path | 사용자·프로젝트 메타데이터 DB |
| `gitlab-minio` | `gitlab-minio-pv` | 10Gi | manual | LFS, 빌드 아티팩트 |
| `redis-data-gitlab-redis-master-0` | `gitlab-redis-pv` | 10Gi | manual | 세션 및 백그라운드 작업 큐 |

---

## 3. 워크로드 구성

### Deployments (Stateless)

| 컴포넌트 | Replicas | 역할 |
| :--- | :--- | :--- |
| `gitlab-webservice-default` | 2 | Web UI / API (Workhorse 포함) |
| `gitlab-gitlab-shell` | 2 | SSH 기반 Git Push/Pull |
| `gitlab-kas` | 2 | Kubernetes Agent Server |
| `gitlab-registry` | 2 | 내장 컨테이너 이미지 레지스트리 |
| `gitlab-sidekiq-all-in-1-v2` | 1 | 비동기 백그라운드 워커 |
| `gitlab-minio` | 1 | S3 호환 오브젝트 스토리지 |
| `gitlab-toolbox` | 1 | 관리 도구 (백업, rake task) |
| `gitlab-gitlab-exporter` | 1 | Prometheus 메트릭 익스포터 |
| `gitlab-certmanager` | 1 | TLS 인증서 발급·관리 |
| `gitlab-certmanager-cainjector` | 1 | CA 인증서 자동 주입 |
| `gitlab-certmanager-webhook` | 1 | cert-manager 어드미션 웹훅 |

### StatefulSets (Stateful)

| 컴포넌트 | 역할 |
| :--- | :--- |
| `gitlab-gitaly` | Git 저장소 엔진 |
| `gitlab-postgresql` | 관계형 데이터베이스 |
| `gitlab-redis-master` | 캐시 및 메시지 브로커 |

### Jobs (일회성)

| Job | 상태 | 역할 |
| :--- | :--- | :--- |
| `gitlab-migrations` | Completed | DB 스키마 마이그레이션 |
| `gitlab-minio-create-buckets` | Completed | MinIO 초기 버킷 생성 |

---

## 4. 네트워크 통신 명세

| Service | Port | 용도 |
| :--- | :--- | :--- |
| `gitlab-webservice-default` | 8080 / 8181 / 8083 | Web UI, API, Workhorse |
| `gitlab-gitlab-shell` | 22 | SSH Git 접근 |
| `gitlab-registry` | 5000 | 컨테이너 이미지 Push/Pull |
| `gitlab-minio-svc` | 9000 | S3 오브젝트 스토리지 |
| `gitlab-kas` | 8150 / 8151 / 8153 / 8154 | Kubernetes Agent 통신 |
| `gitlab-postgresql` | 5432 | DB 접근 |
| `gitlab-postgresql-metrics` | 9187 | PostgreSQL Prometheus 메트릭 |
| `gitlab-redis-master` | 6379 | Redis 접근 |
| `gitlab-redis-metrics` | 9121 | Redis Prometheus 메트릭 |
| `gitlab-gitlab-exporter` | 9168 | GitLab Prometheus 메트릭 |
| `gitlab-certmanager` | 9402 | cert-manager 메트릭 |
| `gitlab-certmanager-webhook` | 443 / 9402 | 어드미션 웹훅 / 메트릭 |

---

## 5. 주요 Secret 및 ConfigMap

### Secrets (백업 필수)

| Secret | 용도 |
| :--- | :--- |
| `gitlab-gitlab-initial-root-password` | 초기 root 관리자 비밀번호 |
| `gitlab-gitlab-shell-host-keys` | SSH 호스트 키 |
| `gitlab-gitlab-shell-secret` | Shell ↔ Webservice 내부 인증 |
| `gitlab-postgresql-password` | PostgreSQL 접근 비밀번호 |
| `gitlab-redis-secret` | Redis 접근 비밀번호 |
| `gitlab-registry-secret` | Registry 내부 인증 토큰 |
| `gitlab-registry-httpsecret` | Registry HTTP 시크릿 |

---

## 6. 폐쇄망 운영 가이드

### 장애 복구

1. `Retain` 정책 PV의 물리 경로 데이터를 먼저 보호합니다.
2. `gitlab-gitlab-initial-root-password` Secret으로 관리자 권한을 확보합니다.
3. 재배포 후 `gitlab-migrations`, `gitlab-minio-create-buckets` Job 완료를 확인합니다.

### 이미지 관리

모든 이미지는 내부 Harbor 레지스트리에서만 조달합니다.
업데이트 시 `v18.7` 태그 이미지 전체가 Harbor에 존재해야 합니다.
