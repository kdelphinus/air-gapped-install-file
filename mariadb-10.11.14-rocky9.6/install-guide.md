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
sudo dnf localinstall -y --disablerepo='*' common/rpms/*.rpm

# 2. MariaDB RPM 설치
sudo dnf localinstall -y --disablerepo='*' db/rpms/*.rpm
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
[mysqld]
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
max_connections      = 200
innodb_buffer_pool_size = 512M
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

---

## 부록: Galera Cluster 장애 복구 가이드 (Full Crash Recovery)

모든 노드가 비정상 종료되어 서비스가 전면 중단된 경우(Full Crash)의 복구 절차입니다.

> 💡 **[중요] 데이터 디렉토리 경로 확인**
>
> 본 가이드는 표준 설치 문서 기준인 `/app/mariadb_data` 경로를 사용합니다. **실제 서버의 설치 구성에 따라 데이터 경로가 다를 수 있으므로**, 명령어 실행 전 실제 데이터가 저장된 경로를 반드시 확인하고 치환하여 사용하시기 바랍니다.

### 1. 복구 논리 (Logic)

- **최신 트랜잭션 판별:** 모든 노드가 다운된 경우, 가장 최신 트랜잭션(`seqno`)을 보유한 노드를 찾아 Primary(Bootstrap 대상)로 승격시켜야 데이터 유실 및 무거운 전체 동기화(SST)를 방지할 수 있습니다.
- **커스텀 경로 스캔:** 데이터가 커스텀 경로에 저장된 경우, 엔진 내부 상태를 강제 스캔할 때 반드시 `--datadir` 옵션을 명시해야 합니다.

### 2. 복구 절차

#### 1단계: DB 클러스터 상태 확인 및 Primary 노드 판별

1. **프로세스 확인:** 3대 서버 모두에서 MariaDB 프로세스가 없는지 확인합니다. (`ps -ef | grep mysql`)
2. **복구 위치(seqno) 추출:** 3대 서버 모두에서 아래 명령어를 실행하여 트랜잭션 번호를 찾습니다.

    ```bash
    sudo /usr/sbin/mariadbd --wsrep-recover --datadir=/app/mariadb_data
    ```

3. **Primary 노드 선정:** 로그 마지막의 `Recovered position: UUID:seqno` 값 중 **숫자(seqno)가 가장 큰 노드**를 Primary로 선정합니다. (숫자가 같다면 `grastate.dat`의 `safe_to_bootstrap: 1`인 노드 선택)

#### 2단계: Primary 노드 부트스트랩 (Bootstrap)

1. **상태 파일 수정:** Primary 노드의 `/app/mariadb_data/grastate.dat` 파일에서 `safe_to_bootstrap: 1`로 설정합니다.
2. **클러스터 초기화 실행:** Primary 노드에서만 실행합니다.

    ```bash
    sudo galera_new_cluster
    ```

3. **검증:** `sudo mariadb -u root -e "SHOW STATUS LIKE 'wsrep_cluster_size';"` 결과가 `1`인지 확인합니다.

#### 3단계: 나머지 노드 합류 (Join)

1. **서비스 순차 시작:** 나머지 노드에서 **하나씩** 서비스를 시작합니다.

    ```bash
    sudo systemctl start mariadb
    ```

2. **최종 검증:** 아무 노드에서나 `wsrep_cluster_size`가 `3`으로 복구되었는지 확인합니다.

#### 4단계: K8s 애플리케이션 파드 정상화

DB 접속 실패로 `CrashLoopBackOff` 상태인 파드들을 재시작합니다.

```bash
kubectl rollout restart deployment --all -n [네임스페이스]
```

### 3. 최종 복구 체크리스트

| 완료 | 분류 | 점검 대상 및 명령어 | 기준 / 비고 |
| :---: | :--- | :--- | :--- |
| [ ] | **사전 조사** | `ps -ef \| grep mysql` | 3대 모두 잔여 DB 프로세스 없음 |
| [ ] | **상태 추출** | `--wsrep-recover --datadir=[경로]` | 3대 중 `seqno` 최고값 판별 완료 |
| [ ] | **부트스트랩** | Primary 노드: `sudo galera_new_cluster` | `wsrep_cluster_size` = 1 확인 |
| [ ] | **노드 합류** | 나머지 노드: `sudo systemctl start mariadb` | `wsrep_cluster_size` = 3 확인 |
| [ ] | **파드 복구** | K8s: `kubectl rollout restart deployment` | 앱 파드 `Running` 상태 확인 |

---

## 부록: RHEL 9 기반 DB/HA 구축 트러블슈팅 가이드

RHEL 9(또는 그 파생 배포판)의 강화된 보안 정책으로 인해 비표준 경로(`/app/mariadb_data` 등) 사용 시 발생할 수 있는 주요 이슈와 해결 방법입니다.

### 1. Systemd 보안 정책 충돌 (Read-only file system)

**증상:** `galera_new_cluster` 실행 시 `Errcode: 30 "Read-only file system"` 발생.

**원인:** RHEL 9의 MariaDB 서비스는 `ProtectSystem=full` 정책이 적용되어 시스템 바이너리 경로 및 주요 디렉토리에 대한 쓰기를 차단합니다.

**해결 방법:** Systemd Override 설정을 통해 특정 경로에 대한 쓰기 권한을 부여합니다.

```bash
# 1. Override 디렉토리 생성
sudo mkdir -p /etc/systemd/system/mariadb.service.d

# 2. 보안 정책 완화 설정 작성
sudo tee /etc/systemd/system/mariadb.service.d/override.conf <<'EOF'
[Service]
ProtectSystem=off
ProtectHome=off
PrivateTmp=false
# 실제 사용하는 데이터 디렉토리 경로 명시
ReadWritePaths=/app/mariadb_data
EOF

# 3. 설정 반영 및 재시작
sudo systemctl daemon-reload
sudo systemctl restart mariadb
```

### 2. SEL인천(SELinux) 권한 차단

**증상:** 파일 시스템 권한이 올바름에도 불구하고 Permission Denied 발생 또는 서비스 시작 실패.

**원인:** 커스텀 경로에 MariaDB 데이터베이스 실행에 필요한 보안 컨텍스트(`mysqld_db_t`)가 부여되지 않음.

**해결 방법:** 영구적인 SELinux 정책을 적용합니다.

```bash
# 1. 특정 경로에 MariaDB 데이터 컨텍스트 부여
sudo semanage fcontext -a -t mysqld_db_t "/app/mariadb_data(/.*)?"

# 2. 변경된 정책을 실제 파일 시스템에 적용
sudo restorecon -R -v /app/mariadb_data

# (참고) 정책 확인 명령어
ls -Zd /app/mariadb_data
```

### 3. HA(VIP) 구성 시 아키텍처 주의사항 (데이터 파손 방지)

**상황:** Keepalived 등을 연동하여 VIP(Virtual IP)를 구성할 때 발생하는 이슈.

- **Shared-Nothing 원칙 준수:** Galera Cluster는 각 노드가 독립적인 스토리지를 가져야 합니다. 만약 전통적인 Active-Standby 방식처럼 **동일한 SAN/iSCSI 디스크를 여러 노드에 동시 마운트**하면 파일 시스템 메타데이터가 파손되어 OS가 즉시 디스크를 `Read-only`로 잠급니다.
- **해결책:** 반드시 노드별 로컬 디스크 또는 독립적인 볼륨을 사용하십시오. 스토리지를 공유해야만 하는 환경이라면 전용 클러스터 파일 시스템(예: GFS2)이 필요하지만, Galera 환경에서는 권장되지 않습니다.
- **Failover 점검:** VIP 할당 직후 DB가 멈춘다면, HA 솔루션이 데이터 보호를 위해 노드를 격리(Fencing)하고 있지는 않은지 확인하십시오.
