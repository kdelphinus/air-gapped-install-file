# MariaDB Galera Cluster 백업 동작 확인 가이드

> **환경**: Rocky Linux 9 + MariaDB 10.11.16 Galera Cluster + NetApp NFS
> **백업 위치**: `/bkup001/dump/`
> **작성일**: 2026-05-15 / 버전 1.0

---

## 이 문서는

매일 새벽 02:00 에 도는 자동 백업이 **정상적으로 동작하고 있는지** 일상적으로 확인하는 절차입니다.

실제 복구가 필요할 때는 별도 문서 `mariadb-galera-restore-guide.md` 를 사용합니다.

---

## 환경 정보

| 항목 | 값 |
|------|-----|
| 백업 노드 | 백업 전담 노드 (LGEDK8SCMP03V) |
| 백업 디렉터리 | `/bkup001/dump/` |
| 로그 디렉터리 | `/bkup001/logs/` |
| 백업 정책 | 매일 02:00, 7일 보관 |
| 백업 timer | `mariadb-backup-dump.timer` |

---

## 1. 일일 확인 (5분)

백업 전담 노드에서 실행.

### 1.1 오늘 백업 파일 확인

```bash
sudo ls -lah /bkup001/dump/ | tail -5
```

**예상 출력 예시**:

```text
-rw-r-----. 1 mysql mysql  792M May 14 02:00 mariadb_full_20260514_020001.sql.gz
-rw-r-----. 1 mysql mysql  795M May 15 02:00 mariadb_full_20260515_020003.sql.gz
```

✅ **확인할 것**:

- 마지막 파일이 **오늘 날짜 02:00** 인가?
- 크기가 **0 바이트가 아닌가**?
- 어제 대비 크기가 **극단적으로 다르지 않은가**? (예: 800MB → 10MB 는 비정상)

### 1.2 백업 로그 확인

```bash
sudo bash -c 'ls -t /bkup001/logs/dump_*.log | head -1 | xargs tail -15'
```

**예상 출력**:

```text
[2026-05-15 02:00:01] === mysqldump Backup Start (MariaDB 10.11.16) ===
[2026-05-15 02:00:01] wsrep enabled — will toggle wsrep_desync
[2026-05-15 02:00:01] Setting wsrep_desync=ON
[2026-05-15 02:42:18] Setting wsrep_desync=OFF
[2026-05-15 02:42:18] Gzip integrity OK
[2026-05-15 02:42:18] Duration: 2537s, Size: 833000000 bytes
[2026-05-15 02:42:18] === mysqldump Backup End ===
[2026-05-15 02:42:18] Retention cleanup done (kept last 7 days)
```

✅ **확인할 것**:

- `=== mysqldump Backup End ===` 메시지가 있는가?
- `Gzip integrity OK` 가 있는가?
- `Setting wsrep_desync=OFF` 가 있는가?
- `ERROR` 또는 `FAILED` 단어가 **없는가**?

### 1.3 wsrep_desync 가 OFF 인지 확인

```bash
sudo mysql -u root -p -e "SHOW VARIABLES LIKE 'wsrep_desync';"
```

**예상 출력**:

```text
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| wsrep_desync  | OFF   |
+---------------+-------+
```

✅ `OFF` 여야 정상.

> ⚠️ `ON` 으로 나오면 백업이 비정상 종료된 상태. 응급조치:
>
> 먼저 백업 프로세스가 끝났는지 확인:
>
> ```bash
> ps -ef | grep -E "mariadb-dump|backup-dump.sh" | grep -v grep
> ```
>
> 프로세스가 없으면 수동으로 OFF:
>
> ```bash
> sudo mysql -u root -p -e "SET GLOBAL wsrep_desync=OFF;"
> ```

### 1.4 다음 백업 예약 확인

```bash
sudo systemctl list-timers --all | grep mariadb
```

**예상 출력**:

```text
NEXT                        LEFT    LAST                        PASSED  UNIT
Sat 2026-05-16 02:00:00 KST 15h     Fri 2026-05-15 02:00:00 KST 7h ago  mariadb-backup-dump.timer
```

✅ **확인할 것**:

- `NEXT` 가 다음 날 02:00 인가?
- `LAST` 가 오늘 02:00 인가?

### 1.5 일일 확인 요약

```text
□ 오늘 02:00 백업 파일 존재 (크기 정상)
□ 로그에 "Backup End" + "Gzip integrity OK"
□ wsrep_desync = OFF
□ timer NEXT 가 다음 날 02:00
```

4개 모두 통과 → 정상. 하나라도 실패 → 5장 트러블슈팅.

---

## 2. 주간 확인 (10분)

매주 월요일 (또는 협의된 요일).

### 2.1 NFS 마운트 / 디스크

```bash
mount | grep bkup001
df -h /bkup001
```

**예상 출력**:

```text
nas.internal:/vol/mariadb_backup on /bkup001 type nfs (rw,relatime,vers=4.1,...)

Filesystem                       Size  Used Avail Use% Mounted on
nas.internal:/vol/mariadb_backup 500G  120G  380G  24% /bkup001
```

✅ **확인할 것**:

- `/bkup001` 가 마운트되어 있는가?
- 디스크 사용률이 **80% 미만** 인가?

### 2.2 7일치 백업 파일 점검

```bash
sudo ls -lah /bkup001/dump/ | grep mariadb_full_
```

**예상 출력 예시**:

```text
-rw-r-----. 1 mysql mysql  780M May 09 02:00 mariadb_full_20260509_020001.sql.gz
-rw-r-----. 1 mysql mysql  782M May 10 02:00 mariadb_full_20260510_020003.sql.gz
-rw-r-----. 1 mysql mysql  785M May 11 02:00 mariadb_full_20260511_020002.sql.gz
-rw-r-----. 1 mysql mysql  788M May 12 02:00 mariadb_full_20260512_020001.sql.gz
-rw-r-----. 1 mysql mysql  790M May 13 02:00 mariadb_full_20260513_020002.sql.gz
-rw-r-----. 1 mysql mysql  792M May 14 02:00 mariadb_full_20260514_020001.sql.gz
-rw-r-----. 1 mysql mysql  795M May 15 02:00 mariadb_full_20260515_020003.sql.gz
```

✅ **확인할 것**:

- 7일치가 모두 존재하는가?
- 크기 추세가 합리적인가? (점진적 증가, 어느 날만 절반 이하 등 없음)

### 2.3 보관 정책 동작 확인

8일 이전 파일이 자동 삭제되고 있는지:

```bash
sudo find /bkup001/dump -name "mariadb_full_*.sql.gz" -mtime +7
sudo find /bkup001/logs -name "dump_*.log" -mtime +7
```

**예상 출력**: **출력이 비어있어야 정상**.

8일 이전 파일이 보이면 retention cleanup 이 동작하지 않은 것입니다.

### 2.4 최근 7일 로그에 에러 검색

```bash
sudo grep -E "ERROR|FAILED|Access denied" /bkup001/logs/dump_*.log
```

**예상 출력**: **비어있어야 정상**.

### 2.5 주간 확인 요약

```text
□ NFS 마운트 정상, 디스크 < 80%
□ 7일치 백업 모두 존재, 크기 추세 정상
□ 8일 이전 파일 없음 (retention 동작)
□ 최근 7일 로그에 에러 없음
```

---

## 3. 복원 가능 여부 확인 (선택, 분기 1회 권장)

백업 파일이 실제로 복원 가능한지 확인하려면, **별도 검증용 인스턴스** 또는 사용하지 않는 노드에서 실제로 import 해 보는 것이 가장 확실합니다.

절차는 복구 가이드(`mariadb-galera-restore-guide.md`) 3~4장과 동일하되, **운영 클러스터가 아닌 별도 환경에서** 진행해야 합니다.

> ⚠️ 운영 클러스터의 한 노드에 import 하면 wsrep 으로 전체 노드에 전파되어 클러스터 전체 데이터가 덮어써집니다. **반드시 운영과 분리된 환경에서.**

가벼운 점검으로는 백업 파일에 어떤 DB 가 들어있는지 확인하는 정도면 충분합니다:

```bash
sudo zcat /bkup001/dump/mariadb_full_<날짜>_020001.sql.gz \
  | grep "^-- Current Database:" \
  | head -30
```

운영 클러스터에 있는 DB 가 모두 들어있는지 확인합니다.

---

## 4. 부록: 자주 쓰는 명령어

### 4.1 일일 점검 한 번에 보기

```bash
sudo bash -c '
  echo "=== 최신 백업 파일 ==="
  ls -lah /bkup001/dump/ | tail -3
  echo ""
  echo "=== 최신 로그 (마지막 15줄) ==="
  ls -t /bkup001/logs/dump_*.log | head -1 | xargs tail -15
  echo ""
  echo "=== wsrep_desync ==="
  mysql -u root -p -e "SHOW VARIABLES LIKE \"wsrep_desync\";"
  echo ""
  echo "=== timer ==="
  systemctl list-timers --all | grep mariadb
'
```

### 4.2 백업 파일 내용 확인

```bash
# 백업에 포함된 DB 목록
sudo zcat /bkup001/dump/mariadb_full_<날짜>.sql.gz \
  | grep "^-- Current Database:" \
  | head -30

# 특정 테이블 포함 여부
sudo zcat /bkup001/dump/mariadb_full_<날짜>.sql.gz \
  | grep -E "^-- Table structure for table \`<테이블명>\`"
```

### 4.3 수동 백업 실행

자동 timer 와 별개로 즉시 백업이 필요할 때:

```bash
sudo -u mysql /opt/mariadb-backup/backup-dump.sh
```

---

## 5. 트러블슈팅

### 5.1 자주 발생하는 증상

| 증상 | 원인 | 해결 |
|------|------|------|
| 오늘 백업 파일 없음 | timer 정지, NFS 끊김, mariadb 정지 등 | 5.2 절 차례대로 확인 |
| 백업 파일 크기 0 | 백업 도중 실패 | 로그(`/bkup001/logs/dump_*.log`)에서 원인 확인 후 수동 재실행 |
| 백업 파일 크기가 갑자기 작아짐 | 일부 DB 빠짐, 또는 실제 데이터 감소 | 백업 내용(4.2 절) 확인. DB 가 빠졌으면 권한·접근성 점검 |
| `wsrep_desync = ON` 으로 잔존 | 백업 비정상 종료 | 1.3 절 응급조치 |
| `gzip: invalid magic` | 백업 파일 손상 | 이전 날짜 백업으로 복구 시도. 7일치 모두 실패하면 백업 시스템 전체 점검 |
| `Access denied for user 'backup_user'` 가 로그에 보임 | 자격증명/권한 문제 | `/etc/mysql/backup.cnf` 와 권한 점검 (가이드 5.1 참조) |
| `ERROR 1227 (SUPER privilege required)` | wsrep_desync 권한 누락 | `backup_user` 에 `GRANT SUPER` 적용 (백업 가이드 5.1 참조) |
| `tee: ... No such file or directory` | `/bkup001/logs/` 미생성 또는 NFS 끊김 | NFS 마운트 확인 + `mkdir -p /bkup001/{dump,logs}` |
| 디스크 사용률 80% 초과 | 데이터 증가 또는 retention 미동작 | 용량 증설 또는 retention 점검 |
| `Backup already running (lock held)` | 직전 백업 실행 중이거나 락 파일 잔존 | `ps -ef | grep backup-dump` 로 프로세스 확인. 없으면 `sudo rm -f /var/lib/mariadb-backup/backup.lock` |

### 5.2 백업이 안 도는 경우 점검 순서

```bash
# 1. timer 상태
sudo systemctl status mariadb-backup-dump.timer

# 2. 마지막 실행 결과
sudo systemctl status mariadb-backup-dump.service --no-pager

# 3. 서비스 저널
sudo journalctl -u mariadb-backup-dump.service -n 100 --no-pager

# 4. NFS 마운트
mount | grep bkup001
df -h /bkup001

# 5. MariaDB 상태
sudo systemctl status mariadb | grep Active
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"

# 6. 락 파일 잔존 여부
sudo ls -la /var/lib/mariadb-backup/
```

### 5.3 로그 위치

| 로그 | 위치 |
|------|------|
| 백업 작업 로그 (작업별) | `/bkup001/logs/dump_<날짜시각>.log` |
| 백업 서비스 저널 | `sudo journalctl -u mariadb-backup-dump.service -n 200` |
| 백업 timer 저널 | `sudo journalctl -u mariadb-backup-dump.timer -n 100` |
| MariaDB 에러 로그 | `/var/log/mariadb/mariadb.log` |

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|------|------|----------|
| 2026-05-15 | 1.0 | 최초 작성. 일일/주간 확인 절차 |
