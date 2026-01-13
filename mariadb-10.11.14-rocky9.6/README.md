# 🗄️ MariaDB v10.11.14 설치 구성 명세

## 1. 주요 실행 바이너리 및 이미지 (Deployment Info)

MariaDB는 데이터의 영속성이 중요하므로 주로 **StatefulSet** 형식으로 설치됩니다.

- **DB Engine**: MariaDB v10.11.14 (LTS)
- **Storage Engine**: InnoDB (기본)
- **Base OS**: 주로 Rocky Linux 또는 Alpine 기반의 컨테이너 이미지

---

## 2. 필수 시스템 컨테이너 목록 (Container Components)

MariaDB Pod 내부 또는 주변에서 실행되는 주요 컨테이너 및 역할입니다.

| 컨테이너명 | 역할 | 비고 |
| --- | --- | --- |
| **mariadb** | 실제 데이터베이스 엔진. SQL 쿼리 처리 및 데이터 저장 수행 | 메인 컨테이너 |
| **metrics-exporter** | (선택사항) Prometheus 모니터링을 위한 DB 상태 지표 추출기 | Sidecar |
| **init-db** | 최초 설치 시 데이터베이스 스키마 및 초기 계정 생성 | Init Container |
| **config-reloader** | `my.cnf` 설정 변경 시 프로세스에 반영하는 보조 도구 | Sidecar |

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
| **mariadb** | **3306** | ClusterIP / NodePort | 애플리케이션(GitLab 등)의 DB 접속 엔드포인트 |

---

## 🛠️ 운영자 가이드 (폐쇄망 팁)

1. **데이터 보존**: MariaDB 설치 시 사용한 PVC가 삭제되지 않도록 주의하십시오. 만약 `statefulset`을 재설치하더라도 동일한 PVC를 마운트하면 데이터는 유지됩니다.
2. **백업**: `mysqldump`를 활용한 정기적인 논리 백업 스케줄링을 `Job`이나 `CronJob`으로 구성하는 것이 좋습니다.
3. **버전 특성**: 10.11 버전은 LTS 버전이므로 2028년까지 보안 업데이트가 지원됩니다.
