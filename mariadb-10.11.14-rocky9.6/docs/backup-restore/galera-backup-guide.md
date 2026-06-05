# MariaDB Galera Cluster 백업 설치 및 적용 가이드

> **대상 환경**: Rocky Linux 9 + MariaDB Galera Cluster (RPM 직접 설치) + NetApp NFS (NAS)  
> **백업 도구**: `mariadb-backup` (메인) + `mariadb-dump` (보조)  
> **작성일**: 2026-04-28

---

## 목차

1. [개요](#1-개요)
2. [백업 전략](#2-백업-전략)
3. [사전 준비](#3-사전-준비)
4. [NAS(NFS) 마운트 구성](#4-nasnfs-마운트-구성)
5. [백업 디렉터리 및 권한 설정](#5-백업-디렉터리-및-권한-설정)
6. [백업 전용 DB 계정 생성](#6-백업-전용-db-계정-생성)
7. [Binary Log 활성화 (PITR용)](#7-binary-log-활성화-pitr용)
8. [백업 스크립트 작성](#8-백업-스크립트-작성)
9. [systemd Timer 등록](#9-systemd-timer-등록)
10. [검증 방법](#10-검증-방법)
11. [복구 절차](#11-복구-절차)
12. [트러블슈팅](#12-트러블슈팅)
13. [부록: 보관 정책 요약표](#13-부록-보관-정책-요약표)

---

## 1. 개요

### 1.1 백업 도구 조합

| 도구 | 역할 | 백업 방식 |
|------|------|----------|
| `mariadb-backup` | 메인 (전체/증분 백업, 빠른 복구) | 물리 백업 |
| `mariadb-dump` | 보조 (부분 복구, 마이그레이션, 검증) | 논리 백업 |
| Binary Log | PITR (특정 시점 복구) | 트랜잭션 로그 |

### 1.2 백업 노드 정책

Galera 클러스터의 모든 노드는 동일한 데이터를 가지므로, **백업은 단일 노드에서만 수행**합니다.

- **백업 전담 노드** 1대 지정 (예: `db-node-3`)
- 백업 작업 시 해당 노드를 desync 모드로 전환하여 flow control 영향 최소화
- 백업 노드 장애에 대비해 다른 노드에도 스크립트는 배포해두되, **timer는 1대에서만 활성화**

### 1.3 NAS 저장 구조

```
NetApp NFS
└── /vol/mariadb_backup
    ├── full/         # 주간 Full 백업 (4주 보관)
    ├── incr/         # 일일 Incremental (7일 보관)
    ├── dump/         # mysqldump 보조 백업 (4주 보관)
    ├── binlog/       # Binary Log 아카이브 (14일 보관)
    ├── archive/      # 월간/연간 장기 보관 (12개월~)
    │   └── monthly/
    ├── logs/         # 백업 작업 로그
    └── scripts/      # (선택) 스크립트는 로컬에 두는 것을 권장
```

---

## 2. 백업 전략

### 2.1 스케줄

| 시간 | 작업 | 도구 |
|------|------|------|
| 매일 02:00 (월~토) | Incremental | mariadb-backup |
| 일요일 02:00 | Full | mariadb-backup |
| 일요일 04:00 | 논리 백업 (Full) | mariadb-dump |
| 매월 1일 05:00 | 월간 아카이브 복사 | (스크립트) |
| 실시간 | Binary Log | MariaDB 자체 |

### 2.2 보관 주기

| 백업 종류 | 보관 기간 | 위치 |
|-----------|----------|------|
| Incremental | 7일 | NAS `/backup/incr/` |
| Full | 4주 (28일) | NAS `/backup/full/` |
| mysqldump | 4주 | NAS `/backup/dump/` |
| Binary Log | 14일 | NAS `/backup/binlog/` |
| 월간 아카이브 | 12개월 | NAS `/backup/archive/monthly/` |
| 연간 아카이브 | 3~5년 | 오프라인 매체 (수동 반출) |

---

## 3. 사전 준비

### 3.1 패키지 설치 확인

```bash
# 버전 확인 (서버와 backup 도구의 버전이 일치해야 함)
mariadb --version
mariadb-backup --version
mariadb-dump --version

# 패키지 설치 여부
rpm -qa | grep -iE "mariadb|maria"
```

**기대 결과**: `mariadb-server`, `mariadb-backup`, `mariadb` (클라이언트) 모두 설치되어 있어야 합니다.

### 3.2 Galera 클러스터 상태 확인

```bash
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
```

**기대 결과**:
- `wsrep_cluster_size`: 3 (3-node 기준)
- `wsrep_local_state_comment`: `Synced`
- `wsrep_cluster_status`: `Primary`

---

## 4. NAS(NFS) 마운트 구성

### 4.1 NFS 마운트 정보 확인

스토리지 담당자로부터 다음 정보를 확보합니다:
- NFS 서버 주소 (예: `nas.internal`)
- Export 경로 (예: `/vol/mariadb_backup`)
- NFS 버전 (NFSv4.1 권장)
- 권한 (백업 노드에서 read/write)

### 4.2 NFS 클라이언트 패키지 설치

```bash
sudo dnf install -y nfs-utils
```

### 4.3 마운트 테스트

```bash
# 마운트 디렉터리 생성
sudo mkdir -p /backup

# 임시 마운트로 테스트 (nconnect 는 NFSv4.1 이상에서만 동작)
sudo mount -t nfs -o rw,vers=4.1,hard,nconnect=4 \
  nas.internal:/vol/mariadb_backup /backup

# 마운트 확인
df -h /backup
mount | grep backup

# 쓰기 테스트
sudo touch /backup/.write_test && sudo rm /backup/.write_test
echo "마운트 OK"

# 테스트 후 unmount
sudo umount /backup
```

### 4.4 영구 마운트 (`/etc/fstab` 등록)

```bash
# /etc/fstab에 추가
sudo tee -a /etc/fstab <<'EOF'
nas.internal:/vol/mariadb_backup  /backup  nfs  rw,vers=4.1,hard,nconnect=4,_netdev,noatime  0 0
EOF

# 재마운트로 검증
sudo mount -a
df -h /backup
```

**옵션 설명**:
- `vers=4.1`: NFSv4.1 명시 (`nfs4` alias 는 4.0 으로 마운트되어 `nconnect` 미지원)
- `hard`: NFS 서버 응답 지연 시 무한 재시도 (데이터 무결성 우선)
- `nconnect=4`: NFSv4.1 multipath, 처리량 향상
- `_netdev`: 네트워크 준비 후 마운트
- `noatime`: 파일 접근 시각 기록 안 함 (성능)

**정확성: 높음** — `nconnect`는 이전에 검토하셨던 NetApp NFSv4.1 Session Trunking 옵션과 일치합니다.

### 4.5 재부팅 후 자동 마운트 검증

```bash
# 재부팅 후
df -h /backup  # 마운트되어 있어야 함
```

⚠️ **재부팅 검증은 운영 노드 투입 전에 반드시 1회 수행**하세요.

---

## 5. 백업 디렉터리 및 권한 설정

```bash
# 디렉터리 구조 생성
sudo mkdir -p /backup/{full,incr,dump,binlog,archive/monthly,logs}

# mysql 사용자 소유로 변경
sudo chown -R mysql:mysql /backup
sudo chmod 750 /backup

# 락 파일 디렉터리 (재부팅 시 살아남도록 /var/lib 사용)
sudo mkdir -p /var/lib/mariadb-backup
sudo chown mysql:mysql /var/lib/mariadb-backup
sudo chmod 750 /var/lib/mariadb-backup

# 결과 확인
sudo ls -la /backup/
```

---

## 6. 백업 전용 DB 계정 생성

### 6.1 계정 및 권한 부여

```bash
sudo mysql -u root -p
```

```sql
-- 백업 전용 계정 생성
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY 'CHANGE_THIS_STRONG_PASSWORD';

-- MariaDB 10.5+ 기준 권한
-- 주의: BACKUP_ADMIN 은 MySQL 8.0 전용 권한이며 MariaDB 에는 존재하지 않음
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR,
      REPLICA MONITOR, SHOW VIEW, EVENT, TRIGGER
      ON *.* TO 'backup_user'@'localhost';

-- mysqldump 및 mariabackup 메타 조회용
GRANT SELECT ON *.* TO 'backup_user'@'localhost';

FLUSH PRIVILEGES;

-- 권한 확인
SHOW GRANTS FOR 'backup_user'@'localhost';

EXIT;
```

> **참고**:
>
> - MariaDB 10.4 이하인 경우 `BINLOG MONITOR`/`REPLICA MONITOR` 대신 `REPLICATION CLIENT` 를 사용합니다.
> - `BACKUP_ADMIN` 은 MySQL 8.0 전용 권한이며 MariaDB 에는 존재하지 않습니다 (GRANT 시 `Unknown privilege` 오류).

### 6.2 자격증명 파일 생성

```bash
# /etc/mysql 디렉터리가 없으면 생성
sudo mkdir -p /etc/mysql

sudo tee /etc/mysql/backup.cnf > /dev/null <<'EOF'
[client]
user=backup_user
password=CHANGE_THIS_STRONG_PASSWORD
socket=/var/lib/mysql/mysql.sock

[mariabackup]
user=backup_user
password=CHANGE_THIS_STRONG_PASSWORD
socket=/var/lib/mysql/mysql.sock

[mariadb-dump]
user=backup_user
password=CHANGE_THIS_STRONG_PASSWORD
socket=/var/lib/mysql/mysql.sock
EOF

# 권한 강화 (필수)
sudo chown mysql:mysql /etc/mysql/backup.cnf
sudo chmod 600 /etc/mysql/backup.cnf
```

### 6.3 자격증명 동작 검증

```bash
sudo -u mysql mysql --defaults-file=/etc/mysql/backup.cnf \
  -e "SELECT CURRENT_USER(), VERSION();"
```

**기대 결과**: `backup_user@localhost` 로 정상 접속되어야 합니다.

---

## 7. Binary Log 활성화 (PITR용)

> **주의**: 이 단계는 **MariaDB 재시작이 필요**하며, Galera 클러스터에서는 **노드를 한 대씩 순차적으로** 재시작해야 합니다.

### 7.1 binlog 디렉터리 생성

```bash
sudo mkdir -p /var/lib/mysql/binlog
sudo chown mysql:mysql /var/lib/mysql/binlog
sudo chmod 750 /var/lib/mysql/binlog
```

### 7.2 설정 파일 수정

`/etc/my.cnf.d/server.cnf` 또는 Galera 설정 파일의 `[mysqld]` 섹션에 추가:

```ini
[mysqld]
# === Binary Log (PITR) ===
log_bin                     = /var/lib/mysql/binlog/mariadb-bin
log_bin_index               = /var/lib/mysql/binlog/mariadb-bin.index
binlog_expire_logs_seconds  = 1209600   # 14일 (expire_logs_days 는 11.x deprecated)
binlog_format               = ROW
sync_binlog                 = 1
log_slave_updates           = ON
```

### 7.3 Rolling Restart (노드별 순차 재시작)

```bash
# === 노드 1번에서 ===
sudo systemctl restart mariadb

# 클러스터 동기화 확인 (Synced가 될 때까지 대기)
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"

# === Synced 확인 후 노드 2번에서 동일 작업 ===
# === 마지막으로 노드 3번에서 ===
```

### 7.4 binlog 동작 확인

```bash
# MariaDB 10.5.2+ 는 SHOW BINLOG STATUS 권장 (SHOW MASTER STATUS 는 alias 로 유지)
sudo mysql -u root -p -e "SHOW BINLOG STATUS;"
sudo ls -la /var/lib/mysql/binlog/
```

**기대 결과**: `mariadb-bin.000001` 같은 파일이 생성되어 있어야 합니다.

---

## 8. 백업 스크립트 작성

### 8.1 공통 함수 스크립트

```bash
sudo mkdir -p /opt/mariadb-backup
```

`/opt/mariadb-backup/common.sh` — `sudo tee` 로 한 번에 작성합니다.
파일을 직접 편집기로 만들 경우 아래 내용을 그대로 붙여넣으세요.

> **주의**: 안쪽 heredoc 종결자 `METRIC` 을 바깥 `EOF` 와 충돌하지 않도록 별도 키워드로 사용합니다.
> 직접 편집기로 작성할 때는 그대로 두면 되고, `sudo tee` 로 작성할 때도 바깥 heredoc 의 종결자와
> 다른 키워드(`SCRIPT`, `METRIC` 등)를 사용해야 파일이 중간에 잘리지 않습니다.

```bash
#!/bin/bash
# 공통 함수 및 변수

# sudo -u mysql 실행 시 cwd 가 호출자 홈(예: /home/rocky, 700 perms)으로 시작되어
# find 가 종료 시 cwd 복귀에 실패하는 경고를 방지하기 위해 mysql 이 접근 가능한
# 디렉터리로 이동.
cd /

BACKUP_ROOT="/backup"
DEFAULTS_FILE="/etc/mysql/backup.cnf"
LOCK_FILE="/var/lib/mariadb-backup/backup.lock"
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-}"  # 선택: Prometheus Pushgateway

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

acquire_lock() {
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log "ERROR: Backup already running"
        exit 1
    fi
}

# 참고: mariabackup 은 Galera 노드에서 자동으로 wsrep_desync ON/OFF 를 수행한다.
# 아래 함수는 mysqldump 등 자동 처리가 없는 도구를 위한 공용 헬퍼이며,
# mariabackup 스크립트에서는 이중 안전장치(실패 시 OFF 보장) 역할만 한다.
set_desync() {
    log "Setting wsrep_desync=ON"
    mysql --defaults-file="${DEFAULTS_FILE}" \
        -e "SET GLOBAL wsrep_desync=ON;"
}

unset_desync() {
    log "Setting wsrep_desync=OFF"
    mysql --defaults-file="${DEFAULTS_FILE}" \
        -e "SET GLOBAL wsrep_desync=OFF;" || true
}

push_metric() {
    local backup_type="$1"
    local status="$2"          # 0=success, 1=fail
    local duration="$3"
    local size_bytes="$4"

    [ -z "${PUSHGATEWAY_URL}" ] && return 0

    # 안쪽 heredoc 종결자는 METRIC 으로 (바깥 EOF 와 충돌 방지)
    cat <<METRIC | curl -sf --data-binary @- \
        "${PUSHGATEWAY_URL}/metrics/job/mariadb_backup/instance/$(hostname)/type/${backup_type}" || true
# TYPE mariadb_backup_last_run_timestamp gauge
mariadb_backup_last_run_timestamp $(date +%s)
# TYPE mariadb_backup_last_status gauge
mariadb_backup_last_status ${status}
# TYPE mariadb_backup_duration_seconds gauge
mariadb_backup_duration_seconds ${duration}
# TYPE mariadb_backup_size_bytes gauge
mariadb_backup_size_bytes ${size_bytes}
METRIC
}
```

### 8.2 Full Backup 스크립트

`/opt/mariadb-backup/backup-full.sh`:

```bash
#!/bin/bash
set -euo pipefail

source /opt/mariadb-backup/common.sh

DATE=$(date +%Y%m%d_%H%M%S)
TARGET_DIR="${BACKUP_ROOT}/full/${DATE}"
LOG_FILE="${BACKUP_ROOT}/logs/full_${DATE}.log"
START_TIME=$(date +%s)

acquire_lock
trap unset_desync EXIT

mkdir -p "${TARGET_DIR}"

{
    log "=== Full Backup Start ==="

    set_desync

    # mariabackup 의 --compress 옵션은 qpress 외부 도구에 의존 (10.5+ deprecated, 11.x 제거 예정).
    # air-gapped 환경에서 qpress RPM 조달 부담을 피하기 위해 백업 후 단계에서 압축한다.
    mariadb-backup --defaults-file="${DEFAULTS_FILE}" \
        --backup \
        --target-dir="${TARGET_DIR}" \
        --galera-info \
        --slave-info \
        --parallel=4

    unset_desync

    # 메타데이터 기록
    cat > "${TARGET_DIR}/backup-info.txt" <<EOF
BACKUP_TYPE=FULL
BACKUP_DATE=${DATE}
HOSTNAME=$(hostname)
EOF
    [ -f "${TARGET_DIR}/xtrabackup_galera_info" ] && \
        cat "${TARGET_DIR}/xtrabackup_galera_info" >> "${TARGET_DIR}/backup-info.txt"

    # 최신 Full 백업 심볼릭 링크 (incremental 기준점)
    ln -sfn "${TARGET_DIR}" "${BACKUP_ROOT}/full/latest"

    log "=== Full Backup End ==="

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    SIZE=$(du -sb "${TARGET_DIR}" | awk '{print $1}')

    log "Duration: ${DURATION}s, Size: ${SIZE} bytes"
    push_metric "full" 0 "${DURATION}" "${SIZE}"

    # 보관 정책: 28일 이상된 Full 백업 삭제
    find "${BACKUP_ROOT}/full" -maxdepth 1 -type d -name "20*" -mtime +28 \
        -exec rm -rf {} \; 2>/dev/null || true

} 2>&1 | tee -a "${LOG_FILE}"
```

### 8.3 Incremental Backup 스크립트

`/opt/mariadb-backup/backup-incremental.sh`:

```bash
#!/bin/bash
set -euo pipefail

source /opt/mariadb-backup/common.sh

DATE=$(date +%Y%m%d_%H%M%S)
TARGET_DIR="${BACKUP_ROOT}/incr/${DATE}"
BASE_DIR="${BACKUP_ROOT}/full/latest"
LOG_FILE="${BACKUP_ROOT}/logs/incr_${DATE}.log"
START_TIME=$(date +%s)

acquire_lock
trap unset_desync EXIT

if [ ! -d "${BASE_DIR}" ]; then
    log "ERROR: Base full backup not found at ${BASE_DIR}"
    push_metric "incremental" 1 0 0
    exit 1
fi

mkdir -p "${TARGET_DIR}"

{
    log "=== Incremental Backup Start ==="
    log "Base: $(readlink -f ${BASE_DIR})"

    set_desync

    mariadb-backup --defaults-file="${DEFAULTS_FILE}" \
        --backup \
        --target-dir="${TARGET_DIR}" \
        --incremental-basedir="${BASE_DIR}" \
        --galera-info \
        --parallel=4

    unset_desync

    log "=== Incremental Backup End ==="

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    SIZE=$(du -sb "${TARGET_DIR}" | awk '{print $1}')

    log "Duration: ${DURATION}s, Size: ${SIZE} bytes"
    push_metric "incremental" 0 "${DURATION}" "${SIZE}"

    # 보관 정책: 7일 이상된 incremental 삭제
    find "${BACKUP_ROOT}/incr" -maxdepth 1 -type d -name "20*" -mtime +7 \
        -exec rm -rf {} \; 2>/dev/null || true

} 2>&1 | tee -a "${LOG_FILE}"
```

### 8.4 mysqldump (보조) 스크립트

`/opt/mariadb-backup/backup-dump.sh`:

```bash
#!/bin/bash
set -euo pipefail

source /opt/mariadb-backup/common.sh

DATE=$(date +%Y%m%d_%H%M%S)
TARGET_FILE="${BACKUP_ROOT}/dump/mariadb_full_${DATE}.sql.gz"
LOG_FILE="${BACKUP_ROOT}/logs/dump_${DATE}.log"
START_TIME=$(date +%s)

acquire_lock
trap unset_desync EXIT

mkdir -p "${BACKUP_ROOT}/dump"

{
    log "=== mysqldump Backup Start ==="

    # mysqldump 는 mariabackup 과 달리 자동 desync 를 수행하지 않으므로
    # 대용량 dump 가 flow control 을 유발하지 않도록 수동으로 desync 처리한다.
    set_desync

    mariadb-dump --defaults-file="${DEFAULTS_FILE}" \
        --all-databases \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        --master-data=2 \
        --flush-logs \
        | gzip -c > "${TARGET_FILE}"

    unset_desync

    # 무결성 검증
    gzip -t "${TARGET_FILE}"
    log "Gzip integrity OK"

    log "=== mysqldump Backup End ==="

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    SIZE=$(stat -c%s "${TARGET_FILE}")

    log "Duration: ${DURATION}s, Size: ${SIZE} bytes"
    push_metric "dump" 0 "${DURATION}" "${SIZE}"

    # 보관 정책: 28일 이상된 dump 삭제
    find "${BACKUP_ROOT}/dump" -name "mariadb_full_*.sql.gz" -mtime +28 -delete

} 2>&1 | tee -a "${LOG_FILE}"
```

### 8.5 Binary Log 동기화 스크립트

`/opt/mariadb-backup/backup-binlog.sh`:

```bash
#!/bin/bash
set -euo pipefail

source /opt/mariadb-backup/common.sh

LOG_FILE="${BACKUP_ROOT}/logs/binlog_$(date +%Y%m%d).log"

{
    log "=== Binlog Sync Start ==="

    # binlog 파일을 NAS로 복사 (rsync, 원본 유지)
    rsync -a --info=progress2 \
        /var/lib/mysql/binlog/mariadb-bin.0* \
        "${BACKUP_ROOT}/binlog/" 2>/dev/null || true

    # 14일 이상된 NAS 측 binlog 삭제
    find "${BACKUP_ROOT}/binlog" -name "mariadb-bin.0*" -mtime +14 -delete

    log "=== Binlog Sync End ==="

} 2>&1 | tee -a "${LOG_FILE}"
```

### 8.6 월간 아카이브 스크립트

`/opt/mariadb-backup/archive-monthly.sh`:

```bash
#!/bin/bash
set -euo pipefail

source /opt/mariadb-backup/common.sh

LATEST_FULL=$(readlink -f "${BACKUP_ROOT}/full/latest")
MONTH=$(date +%Y%m)
ARCHIVE_DIR="${BACKUP_ROOT}/archive/monthly/${MONTH}"
LOG_FILE="${BACKUP_ROOT}/logs/archive_${MONTH}.log"

{
    log "=== Monthly Archive Start ==="
    log "Source: ${LATEST_FULL}"
    log "Target: ${ARCHIVE_DIR}"

    if [ -d "${ARCHIVE_DIR}" ]; then
        log "Archive for ${MONTH} already exists, skipping"
        exit 0
    fi

    # hard link 로 공간 절약하며 복사 (같은 NFS export 내).
    # NetApp NFSv4 는 hard link 를 지원하지만 export policy/볼륨 옵션에 따라 거부될 수 있음.
    # 실패 시 `cp -a` 로 대체하고 보관 정책상 원본 삭제 영향이 없는지 검증할 것.
    cp -al "${LATEST_FULL}" "${ARCHIVE_DIR}"

    log "=== Monthly Archive End ==="

    # 12개월 이상된 월간 아카이브 삭제
    find "${BACKUP_ROOT}/archive/monthly" -maxdepth 1 -type d -mtime +365 \
        -exec rm -rf {} \; 2>/dev/null || true

} 2>&1 | tee -a "${LOG_FILE}"
```

### 8.7 권한 설정

```bash
sudo chmod 750 /opt/mariadb-backup/*.sh
sudo chown -R mysql:mysql /opt/mariadb-backup
sudo ls -la /opt/mariadb-backup/

# 함수 정의가 모두 들어갔는지 검증 (5개 보여야 정상)
sudo grep -n "^[a-z_]\+()" /opt/mariadb-backup/common.sh
# log() / acquire_lock() / set_desync() / unset_desync() / push_metric()
```

---

## 9. systemd Timer 등록

### 9.1 Service 및 Timer 파일 생성

각 백업 작업에 대해 `.service` + `.timer` 페어를 생성합니다.

`/etc/systemd/system/mariadb-backup-full.service`:

```ini
[Unit]
Description=MariaDB Full Backup
After=mariadb.service network-online.target backup.mount
Requires=mariadb.service

[Service]
Type=oneshot
User=mysql
Group=mysql
ExecStart=/opt/mariadb-backup/backup-full.sh
TimeoutStartSec=4h
StandardOutput=journal
StandardError=journal
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

`/etc/systemd/system/mariadb-backup-full.timer`:

```ini
[Unit]
Description=MariaDB Full Backup (Weekly Sunday 02:00)

[Timer]
OnCalendar=Sun *-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/mariadb-backup-incremental.service`:

```ini
[Unit]
Description=MariaDB Incremental Backup
After=mariadb.service network-online.target
Requires=mariadb.service

[Service]
Type=oneshot
User=mysql
Group=mysql
ExecStart=/opt/mariadb-backup/backup-incremental.sh
TimeoutStartSec=2h
StandardOutput=journal
StandardError=journal
Nice=10
```

`/etc/systemd/system/mariadb-backup-incremental.timer`:

```ini
[Unit]
Description=MariaDB Incremental Backup (Daily Mon-Sat 02:00)

[Timer]
OnCalendar=Mon..Sat *-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/mariadb-backup-dump.service`:

```ini
[Unit]
Description=MariaDB mysqldump Backup
After=mariadb.service
Requires=mariadb.service

[Service]
Type=oneshot
User=mysql
Group=mysql
ExecStart=/opt/mariadb-backup/backup-dump.sh
TimeoutStartSec=4h
StandardOutput=journal
StandardError=journal
Nice=15
```

`/etc/systemd/system/mariadb-backup-dump.timer`:

```ini
[Unit]
Description=MariaDB mysqldump Backup (Weekly Sunday 04:00)

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/mariadb-backup-binlog.service`:

```ini
[Unit]
Description=MariaDB Binary Log Sync to NAS

[Service]
Type=oneshot
User=mysql
Group=mysql
ExecStart=/opt/mariadb-backup/backup-binlog.sh
TimeoutStartSec=30m
StandardOutput=journal
StandardError=journal
```

`/etc/systemd/system/mariadb-backup-binlog.timer`:

```ini
[Unit]
Description=MariaDB Binlog Sync (Hourly)

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/mariadb-backup-archive.service`:

```ini
[Unit]
Description=MariaDB Monthly Archive

[Service]
Type=oneshot
User=mysql
Group=mysql
ExecStart=/opt/mariadb-backup/archive-monthly.sh
TimeoutStartSec=2h
StandardOutput=journal
StandardError=journal
```

`/etc/systemd/system/mariadb-backup-archive.timer`:

```ini
[Unit]
Description=MariaDB Monthly Archive (1st day 05:00)

[Timer]
OnCalendar=*-*-01 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

### 9.2 Timer 활성화

```bash
sudo systemctl daemon-reload

sudo systemctl enable --now mariadb-backup-full.timer
sudo systemctl enable --now mariadb-backup-incremental.timer
sudo systemctl enable --now mariadb-backup-dump.timer
sudo systemctl enable --now mariadb-backup-binlog.timer
sudo systemctl enable --now mariadb-backup-archive.timer

# 활성화된 timer 목록 확인
sudo systemctl list-timers --all | grep mariadb
```

**기대 결과 예시**:
```
NEXT                        LEFT       UNIT
Tue 2026-04-28 14:00:00 KST 1h 30min   mariadb-backup-binlog.timer
Wed 2026-04-29 02:00:00 KST 13h        mariadb-backup-incremental.timer
Sun 2026-05-03 02:00:00 KST 5 days     mariadb-backup-full.timer
Sun 2026-05-03 04:00:00 KST 5 days     mariadb-backup-dump.timer
Fri 2026-05-01 05:00:00 KST 3 days     mariadb-backup-archive.timer
```

---

## 10. 검증 방법

### 10.1 단계별 수동 검증 (운영 투입 전 필수)

#### 10.1.1 자격증명 검증

```bash
sudo -u mysql mysql --defaults-file=/etc/mysql/backup.cnf \
  -e "SELECT CURRENT_USER();"
```

✅ **통과 기준**: `backup_user@localhost` 출력

#### 10.1.2 mariadb-backup 수동 실행 (작은 테스트)

```bash
# 테스트용 디렉터리
sudo mkdir -p /backup/test
sudo chown mysql:mysql /backup/test

# Full 백업 수동 실행
sudo -u mysql mariadb-backup \
  --defaults-file=/etc/mysql/backup.cnf \
  --backup \
  --target-dir=/backup/test/manual_test \
  --galera-info
```

✅ **통과 기준**: 마지막 줄에 `[00] Completed OK!` 출력

#### 10.1.3 백업 파일 구조 확인

```bash
sudo ls -la /backup/test/manual_test/
sudo cat /backup/test/manual_test/xtrabackup_galera_info
sudo cat /backup/test/manual_test/xtrabackup_checkpoints
```

✅ **통과 기준**:
- `xtrabackup_galera_info`에 GTID (`<UUID>:<seqno>` 형식) 존재
- `xtrabackup_checkpoints`에 `backup_type = full-backuped` 표시

#### 10.1.4 Prepare 검증

```bash
sudo -u mysql mariadb-backup \
  --prepare \
  --target-dir=/backup/test/manual_test
```

✅ **통과 기준**: `completed OK!` 출력

#### 10.1.5 테스트 디렉터리 정리

```bash
sudo rm -rf /backup/test
```

### 10.2 운영 스크립트 수동 실행 검증

```bash
# Full 백업 스크립트 직접 실행
sudo -u mysql /opt/mariadb-backup/backup-full.sh

# 결과 확인
sudo ls -la /backup/full/
sudo ls -la /backup/full/latest/
sudo bash -c 'tail -n 50 /backup/logs/full_*.log'   # /backup 이 mysql:mysql 750 이라 wildcard 는 sudo 안에서 확장

# Incremental 백업도 검증 (Full이 있어야 가능)
sudo -u mysql /opt/mariadb-backup/backup-incremental.sh

sudo ls -la /backup/incr/

# mysqldump 검증
sudo -u mysql /opt/mariadb-backup/backup-dump.sh
sudo ls -lah /backup/dump/
```

✅ **통과 기준**:
- 각 디렉터리에 백업 파일/디렉터리 생성됨
- 로그 파일에 에러 없음
- 백업 종료 시 `wsrep_desync=OFF` 복구되었는지 확인

```bash
sudo mysql -u root -p -e "SHOW VARIABLES LIKE 'wsrep_desync';"
```

### 10.3 Timer 동작 검증

```bash
# Timer 상태 확인
sudo systemctl status mariadb-backup-incremental.timer
sudo systemctl status mariadb-backup-full.timer

# 다음 실행 예정 시각 확인
sudo systemctl list-timers --all | grep mariadb

# Timer 강제 트리거 테스트 (선택)
sudo systemctl start mariadb-backup-incremental.service
sudo journalctl -u mariadb-backup-incremental.service -f
```

### 10.4 정기 검증 (주/월간)

#### 10.4.1 주간: 백업 무결성 확인

```bash
# 가장 최근 Full 백업이 prepare 가능한지 검증 (사본에서)
LATEST=$(sudo readlink -f /backup/full/latest)
TEST_COPY=/tmp/backup_verify_$(date +%s)

sudo cp -r "${LATEST}" "${TEST_COPY}"
sudo mariadb-backup --prepare --target-dir="${TEST_COPY}"
# completed OK! 확인 후
sudo rm -rf "${TEST_COPY}"
```

#### 10.4.2 월간: 별도 환경 복구 리허설

> **CC 인증에서 자주 요구되는 항목**입니다. 별도 테스트 노드에서 진행하세요.

```bash
# 테스트 노드에서
sudo systemctl stop mariadb
sudo mv /var/lib/mysql /var/lib/mysql.bak

# Prepare
sudo mariadb-backup --prepare --target-dir=/backup/full/latest

# Copy back
sudo mariadb-backup --copy-back --target-dir=/backup/full/latest
sudo chown -R mysql:mysql /var/lib/mysql

sudo systemctl start mariadb

# 데이터 검증
sudo mysql -e "SHOW DATABASES;"
sudo mysql -e "SELECT table_schema, COUNT(*) FROM information_schema.tables GROUP BY table_schema;"
```

✅ **통과 기준**: 모든 데이터베이스/테이블이 원본과 동일하게 복구됨

#### 10.4.3 NAS 저장 상태 확인

```bash
# NAS 용량
df -h /backup

# 백업별 용량
sudo du -sh /backup/full/* /backup/incr/* /backup/dump/* 2>/dev/null

# 최근 7일 내 생성된 백업 파일 (정상 동작 확인)
sudo find /backup -mtime -7 -type f | head -20

# 보관 정책 동작 확인 (오래된 것이 자동 삭제되는지)
sudo find /backup/incr -maxdepth 1 -type d -mtime +7  # 결과 없어야 정상
sudo find /backup/full -maxdepth 1 -type d -mtime +28  # 결과 없어야 정상
```

### 10.5 모니터링 메트릭 (선택)

Pushgateway 사용 시 Prometheus에서 다음 쿼리로 확인:

```promql
# 마지막 Full 백업이 8일 이상 갱신되지 않으면 경고
time() - mariadb_backup_last_run_timestamp{type="full"} > 8 * 86400

# 마지막 Incremental이 25시간 이상 갱신되지 않으면 경고
time() - mariadb_backup_last_run_timestamp{type="incremental"} > 25 * 3600

# 백업 실패
mariadb_backup_last_status > 0
```

### 10.6 검증 체크리스트

| 항목 | 빈도 | 통과 기준 |
|------|------|----------|
| 자격증명 동작 | 1회 (구축 시) | backup_user 정상 접속 |
| 수동 백업 실행 | 1회 (구축 시) | `Completed OK!` |
| Prepare 검증 | 1회 (구축 시) | `completed OK!` |
| Timer 등록 | 1회 (구축 시) | `list-timers`에 표시 |
| 백업 파일 생성 | 매일 | NAS에 새 디렉터리 생성 |
| 보관 정책 동작 | 매주 | 오래된 백업 자동 삭제 |
| desync 해제 | 매회 | `wsrep_desync=OFF` |
| 무결성 prepare | 매주 | sample 백업 prepare 성공 |
| 복구 리허설 | 매월 | 테스트 노드에서 데이터 복구 |
| NAS 용량 | 매주 | 사용률 80% 미만 |
| 모니터링 알람 | 상시 | Prometheus 메트릭 정상 |

---

## 11. 복구 절차

### 11.1 Full 백업만으로 복구

```bash
sudo systemctl stop mariadb
sudo mv /var/lib/mysql /var/lib/mysql.bak

# Prepare
sudo mariadb-backup --prepare --target-dir=/backup/full/20260426_020000

# 데이터 디렉터리로 복구
sudo mariadb-backup --copy-back --target-dir=/backup/full/20260426_020000
sudo chown -R mysql:mysql /var/lib/mysql

sudo systemctl start mariadb
sudo mysql -e "SHOW DATABASES;"
```

### 11.2 Full + Incremental 복구

```bash
# MariaDB mariabackup 은 Percona XtraBackup 과 달리 --apply-log-only 없이
# 순차 prepare 만으로 incremental 체인을 적용한다 (10.11.16 등 일부 빌드는
# --apply-log-only 자체를 인식하지 못함).
# 참고: https://mariadb.com/kb/en/incremental-backup-and-restore-with-mariabackup/

# 1. Full prepare
sudo mariadb-backup --prepare \
  --target-dir=/backup/full/20260426_020000

# 2. Incremental 을 시간순으로 차례대로 적용
sudo mariadb-backup --prepare \
  --target-dir=/backup/full/20260426_020000 \
  --incremental-dir=/backup/incr/20260427_020000

sudo mariadb-backup --prepare \
  --target-dir=/backup/full/20260426_020000 \
  --incremental-dir=/backup/incr/20260428_020000

# 4. Copy back
sudo systemctl stop mariadb
sudo mv /var/lib/mysql /var/lib/mysql.bak
sudo mariadb-backup --copy-back --target-dir=/backup/full/20260426_020000
sudo chown -R mysql:mysql /var/lib/mysql
sudo systemctl start mariadb
```

### 11.3 Galera 클러스터 전체 재구성

```bash
# 1. 모든 노드에서 mariadb 정지
# 2. 첫 번째 노드(부트스트랩 노드)에서 위 11.1 또는 11.2 절차로 복구
# 3. 부트스트랩으로 시작
sudo galera_new_cluster

# 4. 클러스터 상태 확인
sudo mysql -e "SHOW STATUS LIKE 'wsrep_cluster_size';"

# 5. 나머지 노드들을 순차적으로 시작 (SST로 자동 동기화)
#    노드 2번
sudo systemctl start mariadb
#    Synced 확인 후 노드 3번
sudo systemctl start mariadb
```

### 11.4 PITR (특정 시점 복구)

```bash
# 1. 가장 가까운 Full + Incremental로 복구 (위 11.2)
# 2. 복구 후 mariadb 시작
# 3. Binary Log를 원하는 시점까지 적용

sudo mysqlbinlog \
  --start-position=<백업의 binlog 위치> \
  --stop-datetime="2026-04-28 13:30:00" \
  /backup/binlog/mariadb-bin.000123 \
  /backup/binlog/mariadb-bin.000124 \
  | sudo mysql -u root -p
```

---

## 12. 트러블슈팅

### 12.1 백업 실패 시 점검 순서

```bash
# 1. 백업 로그 확인
sudo bash -c 'tail -n 100 /backup/logs/full_*.log'   # 여러 파일에는 -n 형식 필요
sudo journalctl -u mariadb-backup-full.service -n 100

# 2. wsrep_desync 상태 확인 (실패 시 ON으로 남아있을 수 있음)
sudo mysql -u root -p -e "SHOW VARIABLES LIKE 'wsrep_desync';"
# 만약 ON이면 수동으로 OFF
sudo mysql -u root -p -e "SET GLOBAL wsrep_desync=OFF;"

# 3. NAS 마운트 상태
mount | grep backup
df -h /backup

# 4. 디스크 공간
df -h /backup /var/lib/mysql

# 5. 락 파일 잔존 여부
sudo ls -la /var/lib/mariadb-backup/
# 백업 프로세스가 죽어있다면 락 파일 삭제
sudo rm -f /var/lib/mariadb-backup/backup.lock
```

### 12.2 자주 발생하는 오류

| 증상 | 원인 | 해결 |
|------|------|------|
| `Access denied for user 'backup_user'` | 권한 부족 또는 비밀번호 불일치 | `/etc/mysql/backup.cnf` 권한/비밀번호 재확인 |
| `Failed to connect to MySQL server` | 소켓 경로 불일치 | `socket=` 경로 확인 |
| `xtrabackup_galera_info` 없음 | `--galera-info` 누락 | 스크립트 옵션 확인 |
| Incremental 실패 (`needs a prepared target`) | base full 이 아직 prepare 되지 않음 | `mariadb-backup --prepare --target-dir=full` 을 먼저 실행 후 incremental 적용 |
| `unknown option '--apply-log-only'` | MariaDB mariabackup 일부 빌드에서 미지원 | 옵션 제거 — 순차 `--prepare` 만으로 동일 효과 (MariaDB KB 권장 시퀀스) |
| NFS 마운트 끊김 | 네트워크/스토리지 문제 | `mount -a`, NAS 측 확인 |
| Timer 실행 안 됨 | 시스템 시각/타임존 문제 | `timedatectl` 확인 |

### 12.3 백업 작업 중 노드 장애

백업 노드가 장애나면:

1. 다른 Galera 노드는 정상 동작 (영향 없음)
2. 백업 노드 복구 후 다음 스케줄에 자동 재시도
3. 장애 기간이 길 경우 다른 노드에서 임시 백업 실행:
   ```bash
   sudo -u mysql /opt/mariadb-backup/backup-full.sh
   ```

---

## 13. 부록: 보관 정책 요약표

| 백업 종류 | 위치 | 주기 | 보관 기간 | 자동화 |
|----------|------|------|----------|--------|
| Full | NAS `/backup/full/` | 주 1회 (일요일 02:00) | 28일 | systemd timer + 스크립트 내 `find -mtime` |
| Incremental | NAS `/backup/incr/` | 매일 (월~토 02:00) | 7일 | systemd timer + 스크립트 내 `find -mtime` |
| mysqldump | NAS `/backup/dump/` | 주 1회 (일요일 04:00) | 28일 | systemd timer + 스크립트 내 `find -mtime` |
| Binary Log | 로컬 + NAS `/backup/binlog/` | 실시간 + 시간별 sync | 14일 | `expire_logs_days` + rsync |
| 월간 아카이브 | NAS `/backup/archive/monthly/` | 매월 1일 05:00 | 12개월 | systemd timer + hard link |
| 연간 아카이브 | 오프라인 매체 | 분기/연 1회 | 3~5년 | **수동 반출** (CC 인증 정책 따름) |

---

## 변경 이력

| 일자 | 버전 | 작성자 | 변경 내용 |
|------|------|--------|----------|
| 2026-04-28 | 1.0 | - | 최초 작성 |
| 2026-04-28 | 1.1 | - | MariaDB 10.11 정합성 보정: `BACKUP_ADMIN` 제거, `--compress` 의존성 제거(qpress 회피), NFS `vers=4.1` 명시, `binlog_expire_logs_seconds`/`SHOW BINLOG STATUS`/`--source-data` 적용, mysqldump desync 추가 |

---

> **마무리 체크포인트**:
> - [ ] NAS 마운트 영구 등록 및 재부팅 검증 완료
> - [ ] 백업 전용 계정/자격증명 파일 생성 (chmod 600)
> - [ ] 수동 백업 → prepare → (선택) 복구 리허설 완료
> - [ ] systemd timer 활성화 및 `list-timers` 확인
> - [ ] 모니터링 알람 등록 (Pushgateway/Alertmanager)
> - [ ] 월간 복구 리허설 일정 등록 (CC 인증 대비)