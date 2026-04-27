# 🗄️ MariaDB v10.11.14 설치 구성 명세 (Rocky 8.10)

## 1. 주요 실행 바이너리 및 이미지 (Deployment Info)

MariaDB는 데이터의 영속성이 중요하므로 주로 **StatefulSet** 형식으로 설치되거나, 고가용성을 위해 **Galera Cluster** 형태로 구성됩니다.

- **DB Engine**: MariaDB v10.11.14 (LTS)
- **Storage Engine**: InnoDB (기본)
- **Base OS**: Rocky Linux 8.10 (RHEL 8 기반)

---

## 2. 필수 시스템 컨테이너 목록 (Container Components)

K8s 환경에서 MariaDB Pod 내부 또는 주변에서 실행되는 주요 컨테이너 및 역할입니다.

| 컨테이너명 | 역할 | 비고 |
| --- | --- | --- |
| **mariadb** | 실제 데이터베이스 엔진. SQL 쿼리 처리 및 데이터 저장 수행 | 메인 컨테이너 |
| **metrics-exporter** | (선택사항) Prometheus 모니터링을 위한 DB 상태 지표 추출기 | Sidecar |
| **init-db** | 최초 설치 시 데이터베이스 스키마 및 초기 계정 생성 | Init Container |

---

## 3. 설치 시 핵심 설정 및 자원 (Core Resources)

설치 파일(Helm 또는 YAML)에 정의되어야 할 핵심 파라미터입니다.

- **Storage (PVC)**: 데이터 유실 방지를 위한 전용 볼륨 (최소 10Gi~50Gi 권장, `Retain` 정책)
- **Configuration (ConfigMap)**: `my.cnf` 설정
  - `max_connections`: 동시 접속자 수 설정
  - `innodb_buffer_pool_size`: 성능 최적화의 핵심 파라미터
  - `character-set-server`: `utf8mb4` (한글 및 이모지 지원 필수)
- **Security (Secret)**:
  - `MARIADB_ROOT_PASSWORD`: 관리자 비밀번호
  - `MARIADB_DATABASE`: 초기 생성 데이터베이스 명
  - `MARIADB_USER/PASSWORD`: 애플리케이션 접속용 계정

---

## 4. 네트워크 명세 (Network)

| 서비스 이름 | 포트 | 타입 | 용도 |
| --- | --- | --- | --- |
| **mariadb** | **3306** | ClusterIP / NodePort | 애플리케이션의 DB 접속 엔드포인트 |
| **galera** | **4567, 4568, 4444** | Internal | Galera Cluster 통신용 포트 |

---

## 🛠️ 운영자 가이드 (온라인 설치 팁)

1. **온라인 설치**: 이 가이드는 인터넷이 연결된 환경에서 공식 MariaDB Repository를 사용하여 설치하는 과정을 다룹니다.
2. **데이터 보존**: MariaDB 설치 시 사용한 데이터 디렉토리 또는 PVC가 삭제되지 않도록 주의하십시오.
3. **버전 특성**: 10.11 버전은 LTS 버전이므로 장기간 보안 업데이트가 지원됩니다.
