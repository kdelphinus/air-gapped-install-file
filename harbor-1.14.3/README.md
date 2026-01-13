# 📝 Harbor Container Registry Specification (Air-gapped)

본 문서는 **Harbor v1.14.3** 기반의 엔터프라이즈 컨테이너 레지스트리 시스템 구성 및 운영 명세를 정의합니다.

## 1. 시스템 버전 및 아키텍처 (System Version)

| 항목 | 사양 | 비고 |
| --- | --- | --- |
| **Harbor Version** | **v1.14.3** | 엔터프라이즈 레지스트리 |
| **Storage Class** | **harbor-hostpath-sc** | 호스트 경로 기반 정적 할당 |
| **Database** | PostgreSQL (StatefulSet) | 메타데이터 저장용 |
| **Cache** | Redis (StatefulSet) | 작업 큐 및 세션 관리용 |

---

## 2. 주요 서비스 구성 요소 (Workloads)

Harbor는 기능별로 분리된 여러 컴포넌트가 협업하는 구조입니다.

| 컴포넌트명 | 역할 및 용도 | 비고 |
| --- | --- | --- |
| **harbor-core** | 사용자 인증, API 처리, 프로젝트 관리 등 핵심 로직 | API 서버 |
| **harbor-registry** | 실제 Docker 이미지 데이터 저장 및 Push/Pull 처리 | 2/2 Pod (Registry + Ctl) |
| **harbor-portal** | Harbor 웹 대시보드 UI 제공 | 사용자 접속용 |
| **harbor-jobservice** | 이미지 복제(Replication), 취약점 스캔 등 비동기 작업 처리 | 백그라운드 워커 |
| **harbor-nginx** | 내부 컴포넌트 간 통신을 위한 리버스 프록시 | 인그레스 역할 |

---

## 3. 스토리지 및 네트워크 명세 (Storage & Network)

### 💾 영구 볼륨 (PV/PVC)

Harbor의 이미지가 저장되는 핵심 볼륨입니다.

- **PVC**: `harbor-pvc` (기본: **40Gi**, Bound)
- **PV**: `harbor-pv` (기본: Reclaim Policy: **Retain**)
- **데이터 보존**: 이미지가 저장되는 공간이므로 용량 부족 시 가장 먼저 확장이 필요한 부분입니다.

### 🌐 네트워크 접속 (NodePort)

| 서비스 이름 | 포트(내부:외부) | 타입 | 용도 |
| --- | --- | --- | --- |
| **harbor** | **80:30002** | **NodePort** | **Harbor 웹 접속 및 docker login/push/pull** |

---

## 4. 보안 및 설정 정보 (Secrets & Config)

### 🔐 주요 보안 정보 (Secrets)

- **harbor-core**: 핵심 암호화 키 및 인증 정보.
- **harbor-registry-htpasswd**: 레지스트리 접근 인증 데이터.
- **harbor-database**: PostgreSQL DB 접속 계정 정보.

### ⚙️ 시스템 설정 (ConfigMaps)

- **harbor-core (32 Data)**: 프로젝트 설정, 이메일, 인증 방식(LDAP 등) 정보가 포함된 대규모 설정 파일.
- **harbor-registry**: 스토리지 백엔드(파일시스템) 및 인증 방식 설정.

---

## 5. 폐쇄망 운영 가이드 (Air-gapped Operation)

### ✅ 외부 이미지 반입 절차

1. 외부망에서 필요한 이미지를 `docker pull` 합니다.
2. `docker save`를 통해 `.tar` 파일로 생성 후 폐쇄망으로 반입합니다.
3. 폐쇄망 서버에서 `docker load` 후, **30002번 포트**를 통해 Harbor로 `docker push` 합니다.
   - 예: `docker tag my-image:v1 1.1.1.198:30002/library/my-image:v1`

### ✅ 가용성 및 유지보수

- **하드웨어 디스크 모니터링**: `harbor-hostpath-sc`를 사용 중이므로, 해당 PV가 위치한 **노드의 물리 디스크 잔량**을 주기적으로 확인해야 합니다.
- **로그 관리**: `jobservice` 로그를 통해 이미지 복제나 스캔 작업의 실패 여부를 확인할 수 있습니다.
