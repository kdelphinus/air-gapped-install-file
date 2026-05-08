# MariaDB Galera Cluster 백업 가이드 (단순화 버전)

> **대상 환경**: Rocky Linux 9 + MariaDB **10.11.16** Galera Cluster (RPM 직접 설치) + NetApp NFS (NAS)
> **백업 도구**: `mariadb-dump` (논리 백업)
> **백업 정책**: 매일 1회 Full Dump + 7일 보관 (PITR 미사용)
> **작성일**: 2026-05-08

> **참고**: 본 문서는 증분 백업/Binary Log/월간 아카이브를 모두 사용하는
> 풀 정책 가이드([galera-backup-guide.md](./galera-backup-guide.md))의 단순화 버전입니다.
> RTO/RPO 가 24시간 단위로 허용되는 환경에 적합합니다.

---

## 목차

1. [개요](#1-개요)
2. [사전 준비](#2-사전-준비)
3. [NAS(NFS) 마운트 구성](#3-nasnfs-마운트-구성)
4. [백업 디렉터리 및 권한 설정](#4-백업-디렉터리-및-권한-설정)
5. [백업 전용 DB 계정 생성](#5-백업-전용-db-계정-생성)
6. [백업 스크립트 작성](#6-백업-스크립트-작성)
7. [systemd Timer 등록](#7-systemd-timer-등록)
8. [검증 방법](#8-검증-방법)
9. [복구 절차](#9-복구-절차)
10. [트러블슈팅](#10-트러블슈팅)
11. [변경 이력](#11-변경-이력)

---

## 1. 개요

### 1.1 백업 정책

| 항목 | 내용 |
|------|------|
| 도구 | `mariadb-dump` (논리 백업) |
| 주기 | 매일 02:00 |
| 보관 | 7일 (8일 이상된 파일 자동 삭제) |
| 저장 위치 | NetApp NFS `/backup/dump/` |
| PITR | **미지원** (binary log 미사용) |

### 1.2 백업 노드 정책

Galera 클러스터의 모든 노드는 동일한 데이터를 가지므로, **백업은 단일 노드에서만 수행**합니다.

- **백업 전담 노드** 1대 지정 (예: `db-node-3`)
- 백업 노드 장애 시 다른 노드에서도 즉시 수동 실행할 수 있도록 스크립트는 전 노드에 배포하되, **timer는 1대에서만 활성화**
- 백업 작업 시 해당 노드를 `wsrep_desync=ON` 으로 전환하여 flow control 영향 최소화

### 1.3 NAS 저장 구조

```text
NetApp NFS
└── /vol/mariadb_backup
    ├── dump/    # 일일 덤프 (7일 보관)
    └── logs/    # 백업 작업 로그 (7일 보관)
```

---

## 2. 사전 준비

### 2.1 패키지 설치 확인

```bash
mariadb --version       # 10.11.16 확인
mariadb-dump --version  # 10.11.16 확인
rpm -qa | grep -iE "mariadb|maria"
```

**기대 결과**: `mariadb-server`, `mariadb` (클라이언트) 모두 10.11.16 으로 설치되어 있어야 합니다.

### 2.2 Galera 클러스터 상태 확인

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

## 3. NAS(NFS) 마운트 구성

### 3.1 NFS 클라이언트 패키지 설치

```bash
sudo dnf install -y nfs-utils
```

### 3.2 마운트 테스트

```bash
sudo mkdir -p /backup

# 임시 마운트 테스트 (nconnect은 NFSv4.1 이상에서만 동작)
sudo mount -t nfs -o rw,vers=4.1,hard,nconnect=4 \
  nas.internal:/vol/mariadb_backup /backup

df -h /backup
sudo touch /backup/.write_test && sudo rm /backup/.write_test
echo "마운트 OK"

sudo umount /backup
```

### 3.3 영구 마운트 (`/etc/fstab` 등록)

```bash
sudo tee -a /etc/fstab <<'EOF'
nas.internal:/vol/mariadb_backup  /backup  nfs  rw,vers=4.1,hard,nconnect=4,_netdev,noatime  0 0
EOF

sudo mount -a
df -h /backup
```

**옵션 설명**:

- `vers=4.1`: NFSv4.1 명시 (`nfs4` alias는 4.0 으로 마운트되어 `nconnect` 미지원)
- `hard`: NFS 서버 응답 지연 시 무한 재시도 (데이터 무결성 우선)
- `nconnect=4`: NFSv4.1 multipath, 처리량 향상
- `_netdev`: 네트워크 준비 후 마운트
- `noatime`: 파일 접근 시각 기록 안 함 (성능)

> ⚠️ **재부팅 후 자동 마운트를 운영 투입 전 반드시 1회 검증**하세요: `df -h /backup`

---

## 4. 백업 디렉터리 및 권한 설정

```bash
# 백업 디렉터리
sudo mkdir -p /backup/{dump,logs}
sudo chown -R mysql:mysql /backup
sudo chmod 750 /backup

# 락 파일 디렉터리 (재부팅 후에도 유지되도록 /var/lib 사용)
sudo mkdir -p /var/lib/mariadb-backup
sudo chown mysql:mysql /var/lib/mariadb-backup
sudo chmod 750 /var/lib/mariadb-backup

sudo ls -la /backup/
```

---

## 5. 백업 전용 DB 계정 생성

### 5.1 계정 및 권한 부여

```bash
sudo mysql -u root -p
```

```sql
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY 'CHANGE_THIS_STRONG_PASSWORD';

-- mariadb-dump 에 필요한 최소 권한 (MariaDB 10.11)
GRANT RELOAD, PROCESS, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER
      ON *.* TO 'backup_user'@'localhost';

GRANT SELECT ON *.* TO 'backup_user'@'localhost';

FLUSH PRIVILEGES;
SHOW GRANTS FOR 'backup_user'@'localhost';
EXIT;
```

> **참고**: PITR 미사용 정책이므로 `BINLOG MONITOR` / `REPLICA MONITOR` / `REPLICATION CLIENT` 권한은 필요 없습니다.
> `BACKUP_ADMIN` 은 MySQL 8.0 전용 권한이며 MariaDB 에는 존재하지 않습니다.

### 5.2 자격증명 파일 생성

```bash
sudo mkdir -p /etc/mysql

sudo tee /etc/mysql/backup.cnf > /dev/null <<'EOF'
[client]
user=backup_user
password=CHANGE_THIS_STRONG_PASSWORD
socket=/var/lib/mysql/mysql.sock

[mariadb-dump]
user=backup_user
password=CHANGE_THIS_STRONG_PASSWORD
socket=/var/lib/mysql/mysql.sock
EOF

sudo chown mysql:mysql /etc/mysql/backup.cnf
sudo chmod 600 /etc/mysql/backup.cnf
```

### 5.3 자격증명 동작 검증

```bash
sudo -u mysql mysql --defaults-file=/etc/mysql/backup.cnf \
  -e "SELECT CURRENT_USER(), VERSION();"
```

**기대 결과**: `backup_user@localhost` 로 정상 접속, `VERSION()` 이 `10.11.16-MariaDB...` 출력.

---

## 6. 백업 스크립트 작성

### 6.1 스크립트 디렉터리

```bash
sudo mkdir -p /opt/mariadb-backup
```

### 6.2 백업 스크립트

`/opt/mariadb-backup/backup-dump.sh`:

```bash
#!/bin/bash
set -euo pipefail

# sudo -u mysql 실행 시 cwd 가 호출자 홈(예: /home/rocky, 700 perms)으로 시작되어
# find 가 종료 시 cwd 복귀에 실패하는 경고를 방지하기 위해 mysql 이 접근 가능한
# 디렉터리로 이동.
cd /

BACKUP_ROOT="/backup"
DEFAULTS_FILE="/etc/mysql/backup.cnf"
LOCK_FILE="/var/lib/mariadb-backup/backup.lock"
DATE=$(date +%Y%m%d_%H%M%S)
TARGET_FILE="${BACKUP_ROOT}/dump/mariadb_full_${DATE}.sql.gz"
LOG_FILE="${BACKUP_ROOT}/logs/dump_${DATE}.log"
START_TIME=$(date +%s)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

acquire_lock() {
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log "ERROR: Backup already running (lock held)"
        exit 1
    fi
}

unset_desync() {
    log "Setting wsrep_desync=OFF"
    mysql --defaults-file="${DEFAULTS_FILE}" \
        -e "SET GLOBAL wsrep_desync=OFF;" || true
}

acquire_lock
# 정상 종료 및 비정상 종료(set -e 트리거, 시그널) 모두 desync 해제 보장
trap unset_desync EXIT

{
    log "=== mysqldump Backup Start (MariaDB 10.11.16) ==="

    # Galera 환경에서 대용량 dump 가 flow control 을 유발하지 않도록 desync 처리
    log "Setting wsrep_desync=ON"
    mysql --defaults-file="${DEFAULTS_FILE}" \
        -e "SET GLOBAL wsrep_desync=ON;"

    # 주의: PITR 미사용 정책이므로 --source-data / --flush-logs 는 사용하지 않는다
    # (binlog 비활성 환경에서 --source-data 는 mariadb-dump 에러를 유발).
    mariadb-dump --defaults-file="${DEFAULTS_FILE}" \
        --all-databases \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        | gzip -c > "${TARGET_FILE}"

    # desync OFF 는 trap EXIT 에서 처리

    # 무결성 검증 (gzip 만 검증; 실제 복원 검증은 분기/월 리허설 항목 참조)
    gzip -t "${TARGET_FILE}"
    log "Gzip integrity OK"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    SIZE=$(stat -c%s "${TARGET_FILE}")

    log "Duration: ${DURATION}s, Size: ${SIZE} bytes"
    log "=== mysqldump Backup End ==="

    # 보관 정책: 7일(8일 이상 경과) 초과 덤프 및 로그 자동 삭제
    find "${BACKUP_ROOT}/dump" -name "mariadb_full_*.sql.gz" -mtime +7 -delete
    find "${BACKUP_ROOT}/logs" -name "dump_*.log" -mtime +7 -delete
    log "Retention cleanup done (kept last 7 days)"

} 2>&1 | tee -a "${LOG_FILE}"
```

### 6.3 권한 설정

```bash
sudo chmod 750 /opt/mariadb-backup/backup-dump.sh
sudo chown -R mysql:mysql /opt/mariadb-backup
sudo ls -la /opt/mariadb-backup/
```

---

## 7. systemd Timer 등록

### 7.1 Service 파일

`/etc/systemd/system/mariadb-backup-dump.service`:

```ini
[Unit]
Description=MariaDB Daily mysqldump Backup
After=mariadb.service network-online.target remote-fs.target
Requires=mariadb.service
# NAS(/backup) 가 마운트되어 있지 않으면 서비스 실행 자체가 실패하도록 강제.
# 미설정 시 백업이 로컬 디스크에 쌓여 NAS 보관 정책이 무력화될 수 있음.
RequiresMountsFor=/backup

[Service]
Type=oneshot
User=mysql
Group=mysql
ExecStart=/opt/mariadb-backup/backup-dump.sh
TimeoutStartSec=4h
StandardOutput=journal
StandardError=journal
Nice=15
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

### 7.2 Timer 파일

`/etc/systemd/system/mariadb-backup-dump.timer`:

```ini
[Unit]
Description=MariaDB Daily Backup (02:00)

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

### 7.3 Timer 활성화

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mariadb-backup-dump.timer

sudo systemctl list-timers --all | grep mariadb
```

**기대 결과 예시**:

```text
NEXT                        LEFT    UNIT
Sat 2026-05-09 02:00:00 KST 12h     mariadb-backup-dump.timer
```

---

## 8. 검증 방법

### 8.1 자격증명 검증

```bash
sudo -u mysql mysql --defaults-file=/etc/mysql/backup.cnf \
  -e "SELECT CURRENT_USER(), VERSION();"
```

✅ **통과 기준**: `backup_user@localhost`, `10.11.16-MariaDB...`

### 8.2 수동 백업 실행

```bash
sudo -u mysql /opt/mariadb-backup/backup-dump.sh

sudo ls -lah /backup/dump/
sudo bash -c 'tail -n 50 /backup/logs/dump_*.log'
```

✅ **통과 기준**:

- `/backup/dump/` 에 `mariadb_full_YYYYMMDD_HHMMSS.sql.gz` 생성
- 로그에 `Gzip integrity OK` 및 `mysqldump Backup End` 출력
- 백업 종료 후 `wsrep_desync` 가 OFF 로 복구

```bash
sudo mysql -u root -p -e "SHOW VARIABLES LIKE 'wsrep_desync';"
```

### 8.3 Timer 동작 검증

```bash
sudo systemctl status mariadb-backup-dump.timer
sudo systemctl list-timers --all | grep mariadb

# (선택) 즉시 트리거
sudo systemctl start mariadb-backup-dump.service
sudo journalctl -u mariadb-backup-dump.service -f
```

### 8.4 분기/월 복원 리허설 (필수)

> **논리 덤프는 gzip 무결성 OK 가 곧 복원 가능을 의미하지 않습니다.**
> 운영 데이터로 실제 복원되는지 별도 노드(또는 별도 스키마)에서 정기 검증해야 합니다.

```bash
# 별도 테스트 노드에서 (운영 클러스터에 import 금지 — 9.1 참고)
sudo systemctl stop mariadb
sudo mv /var/lib/mysql /var/lib/mysql.bak
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql
sudo systemctl start mariadb

LATEST=$(ls -t /backup/dump/mariadb_full_*.sql.gz | head -1)
sudo zcat "${LATEST}" | sudo mysql -u root -p

sudo mysql -e "SHOW DATABASES;"
sudo mysql -e "SELECT table_schema, COUNT(*) FROM information_schema.tables GROUP BY table_schema;"
```

✅ **통과 기준**: 모든 사용자 데이터베이스/테이블이 정상 복원됨.

### 8.5 NAS 저장 상태 확인

```bash
df -h /backup
sudo du -sh /backup/dump/*

# 8일 이상된 파일이 없어야 정상 (보관 정책 동작 확인)
sudo find /backup/dump -name "*.sql.gz" -mtime +7
sudo find /backup/logs -name "dump_*.log" -mtime +7
```

### 8.6 검증 체크리스트

| 항목 | 빈도 | 통과 기준 |
|------|------|----------|
| 자격증명 동작 | 1회 (구축 시) | `backup_user@localhost` 접속 |
| 수동 백업 실행 | 1회 (구축 시) | `.sql.gz` 생성 + gzip 무결성 OK |
| Timer 등록 | 1회 (구축 시) | `list-timers` 에 표시 |
| 백업 파일 생성 | 매일 | NAS 에 새 파일 생성 |
| 보관 정책 동작 | 매주 | 8일 이상된 파일/로그 없음 |
| `wsrep_desync` 해제 | 매회 | `wsrep_desync=OFF` |
| NAS 용량 | 매주 | 사용률 80% 미만 |
| **복원 리허설** | **분기/월 1회** | **별도 노드에서 zcat \| mysql 복원 성공** |

---

## 9. 복구 절차

### 9.1 단일 인스턴스(클러스터 외) 복원 — 검증/장애 분석용

> ⚠️ **운영 중인 Galera 클러스터의 한 노드에 그대로 import 하지 마세요.**
> 논리 덤프 import 는 모든 INSERT/CREATE 가 wsrep 으로 전파되어 다른 노드까지
> replication storm + flow control 을 유발합니다. 운영 클러스터 전체 복원은 **9.2** 절차를 따르세요.
> 아래는 별도 노드(또는 클러스터에서 분리한 단일 인스턴스)에서 복원 검증/장애 분석을 위한 절차입니다.

```bash
# 별도 노드에서, mariadb 가 단독 인스턴스로 떠 있는 상태
sudo systemctl stop mariadb
sudo mv /var/lib/mysql /var/lib/mysql.bak
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql
sudo systemctl start mariadb

# 복원: --all-databases 덤프는 mysql.user / GRANT / DEFINER 까지 포함하므로
# 반드시 root 자격으로 import 한다 (backup_user 권한으로는 실패).
sudo zcat /backup/dump/mariadb_full_YYYYMMDD_HHMMSS.sql.gz | sudo mysql -u root -p

sudo mysql -u root -p -e "SHOW DATABASES;"
```

### 9.2 Galera 클러스터 전체 복원

```bash
# 1. 모든 노드에서 mariadb 정지
sudo systemctl stop mariadb   # 노드 1, 2, 3 각각

# 2. 부트스트랩 노드에서 데이터 디렉터리 초기화
sudo mv /var/lib/mysql /var/lib/mysql.bak
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql

# 3. 부트스트랩으로 시작
sudo galera_new_cluster

# 4. root 자격으로 덤프 import
sudo zcat /backup/dump/mariadb_full_YYYYMMDD_HHMMSS.sql.gz | sudo mysql -u root -p

# 5. 클러스터 상태 확인
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"

# 6. 나머지 노드를 순차적으로 시작 (SST 로 자동 동기화)
sudo systemctl start mariadb   # 노드 2 → Synced 확인
sudo systemctl start mariadb   # 노드 3 → Synced 확인
```

✅ **통과 기준**: `wsrep_cluster_size=3`, 모든 노드 `Synced`.

---

## 10. 트러블슈팅

### 10.1 백업 실패 시 점검 순서

```bash
# 1. 로그 확인
sudo bash -c 'tail -n 100 /backup/logs/dump_*.log'
sudo journalctl -u mariadb-backup-dump.service -n 100

# 2. wsrep_desync 잔존 여부 확인 및 수동 해제
sudo mysql -u root -p -e "SHOW VARIABLES LIKE 'wsrep_desync';"
sudo mysql -u root -p -e "SET GLOBAL wsrep_desync=OFF;"

# 3. NAS 마운트 상태
mount | grep backup
df -h /backup

# 4. 디스크 공간
df -h /backup /var/lib/mysql

# 5. 락 파일 잔존 여부 (백업 프로세스가 죽어있다면 삭제)
sudo ls -la /var/lib/mariadb-backup/
sudo rm -f /var/lib/mariadb-backup/backup.lock
```

### 10.2 자주 발생하는 오류

| 증상 | 원인 | 해결 |
|------|------|------|
| `Access denied for user 'backup_user'` | 권한 부족 또는 비밀번호 불일치 | `/etc/mysql/backup.cnf` 권한/비밀번호 재확인 |
| `Failed to connect to MySQL server` | 소켓 경로 불일치 | `socket=` 경로 확인 |
| `gzip: invalid magic` 또는 gzip 검증 실패 | 덤프 도중 중단됨 | 로그에서 원인 확인 후 재실행 |
| 복원 시 `Access denied ... GRANT` | `backup_user` 로 import 시도 | **root 자격으로 import** (9.1/9.2 절차) |
| Service 가 `dependency failed` 로 실행 안 됨 | `/backup` 미마운트 | `sudo mount -a`, `df -h /backup` 확인 |
| NFS 마운트 끊김 | 네트워크/스토리지 문제 | `mount -a`, NAS 측 확인 |
| Timer 실행 안 됨 | 시스템 시각/타임존 문제 | `timedatectl` 확인 |
| `Backup already running (lock held)` | 직전 백업이 아직 실행 중 또는 락 잔존 | 프로세스 확인 후 락 파일 정리 |

### 10.3 백업 노드 장애 시

백업 노드가 장애나면:

1. 다른 Galera 노드는 정상 동작 (영향 없음)
2. 다른 노드에서 스크립트를 즉시 수동 실행:

   ```bash
   sudo -u mysql /opt/mariadb-backup/backup-dump.sh
   ```

3. 백업 노드 복구 후 timer 가 자동으로 다음 스케줄에 재실행됨
   (`Persistent=true` 설정으로 복구 직후 밀린 실행이 1회 트리거됨)

---

## 11. 변경 이력

| 일자 | 버전 | 변경 내용 |
|------|------|----------|
| 2026-04-28 | 1.0 | 풀 정책 가이드 최초 작성 |
| 2026-04-28 | 1.1 | MariaDB 10.11 정합성 보정 |
| 2026-05-08 | 2.0 | 단순화 정책(매일 dump + 7일) 분기 |
| 2026-05-08 | 2.1 | MariaDB **10.11.16** 기준으로 갱신. 리뷰 반영: ① `--source-data`/`--flush-logs` 제거(binlog 비활성과 일관성), ② 스크립트의 line-continuation + 인라인 주석 문법 오류 수정, ③ 복원 명령을 root 자격으로 변경, ④ 9.1 시나리오를 "단일 인스턴스 검증용"으로 한정하고 클러스터 전체 복원은 9.2 로 분리, ⑤ systemd `RequiresMountsFor=/backup` 추가, ⑥ `flock` 동시 실행 가드 복원, ⑦ 분기/월 복원 리허설을 검증 체크리스트에 명시 |

---

> **마무리 체크포인트**:
>
> - [ ] NAS 마운트 영구 등록 및 재부팅 검증 완료
> - [ ] 백업 전용 계정/자격증명 파일 생성 (chmod 600)
> - [ ] 수동 백업 실행 및 gzip 무결성 확인 완료
> - [ ] systemd timer 활성화 및 `list-timers` 확인
> - [ ] `wsrep_desync=OFF` 복구 확인
> - [ ] 분기/월 복원 리허설 일정 등록
