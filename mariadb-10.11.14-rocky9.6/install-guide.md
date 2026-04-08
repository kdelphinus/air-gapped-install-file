# MariaDB v10.11.14 오프라인 설치 가이드 (Rocky Linux 9.6)

폐쇄망 환경에서 MariaDB v10.11.14를 Rocky Linux 9.6에 RPM으로 설치하는 절차를 안내합니다.

## 전제 조건

- Rocky Linux 9.6 서버 (폐쇄망)
- `common/rpms/` 및 `db/rpms/` 디렉토리 내 RPM 파일이 서버에 반입되어 있을 것

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `common/rpms/` | 공통 의존성 RPM |
| `db/rpms/` | MariaDB 10.11.14 RPM 패키지 |
| `backup/` | mariabackup 기반 백업 구성 및 가이드 |

## Phase 1: RPM 설치

```bash
# 1. 공통 의존성 RPM 먼저 설치
sudo dnf localinstall -y --disablerepo='*' --skip-broken common/rpms/*.rpm

# 2. MariaDB RPM 설치
sudo dnf localinstall -y --disablerepo='*' --skip-broken db/rpms/*.rpm
```

## Phase 2: MariaDB 초기 설정

```bash
# MariaDB 서비스 활성화 및 시작
sudo systemctl enable --now mariadb

# 서비스 상태 확인
sudo systemctl status mariadb
```

보안 초기 설정을 실행합니다.

```bash
sudo mysql_secure_installation
```

실행 중 아래 항목을 설정합니다.

- root 비밀번호 설정
- 익명 사용자 삭제 (y)
- 원격 root 로그인 비활성화 (y)
- test 데이터베이스 삭제 (y)
- 권한 테이블 재로드 (y)

## Phase 3: 기본 설정 (my.cnf)

`/etc/my.cnf.d/` 아래 설정 파일을 생성하여 핵심 파라미터를 구성합니다.

```bash
sudo tee /etc/my.cnf.d/custom.cnf <<'EOF'
[mariadb]
# ----------------------------------------------
# 1. 기본 및 호환성 설정 (Basic & Compatibility)
# ----------------------------------------------
# 데이터 경로를 옮길 때만 사용
# datadir=/app/mariadb_data
# 소켓 파일은 가급적 기본 위치 유지 권장 (클라이언트 접속 편의성)
# 만약 소켓도 옮기고 싶다면 socket=/app/mariadb_data/mysql.sock 추가

bind-address=0.0.0.0
default_storage_engine=InnoDB
binlog_format=ROW
innodb_autoinc_lock_mode=2

# [튜닝] 대소문자 구분 안 함 (1 = 무시, 소문자로 저장)
# 주의: 이 설정은 DB 초기화 전에 적용되어야 합니다.
lower_case_table_names=1

# [튜닝] 커넥션 증설 (기본 151 -> 1000)
max_connections=1000

# [튜닝] SQL Mode 완화 (ONLY_FULL_GROUP_BY 제거)
# 쿼리 작성 시 GROUP BY 절 제약을 완화하여 호환성 확보
sql_mode="STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
EOF

sudo systemctl restart mariadb
```

## Phase 4: 초기 데이터베이스 및 사용자 생성

```bash
sudo mysql -u root -p <<'EOF'
CREATE DATABASE IF NOT EXISTS mydb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'StrongPassword!';
GRANT ALL PRIVILEGES ON mydb.* TO 'appuser'@'%';
FLUSH PRIVILEGES;
EOF
```

## Phase 5: 설치 확인

```bash
mysql -u root -p -e "SHOW DATABASES;"
mysql -u root -p -e "SELECT version();"
mysql -u root -p -e "SHOW VARIABLES LIKE 'character_set_server';"
```

## Phase 6: 방화벽 설정 (필요 시)

다른 서버에서 MariaDB에 접근해야 하는 경우 포트를 열어줍니다.

```bash
sudo firewall-cmd --permanent --add-port=3306/tcp
sudo firewall-cmd --reload
```

## 참고: 백업 구성

mariabackup 기반 백업 설정은 `backup/README.md` 를 참조하세요.

## 참고: Galera Cluster 구성

Galera Cluster 3중화 구성, 장애 복구, RHEL 9 트러블슈팅은 `galera-cluster-guide.md` 를 참조하세요.
