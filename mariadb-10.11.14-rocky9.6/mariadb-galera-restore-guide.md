# MariaDB Galera Cluster 복구 가이드

> **환경**: Rocky Linux 9 + MariaDB 10.11.16 Galera Cluster + NetApp NFS
> **백업 위치**: `/bkup001/dump/`
> **작성일**: 2026-05-15 / 버전 1.0

---

## 이 문서는

`mariadb-dump` 로 뜬 백업 파일을 사용해 **데이터베이스를 원상 복구** 하는 절차서입니다.

평시 백업 동작 점검은 별도 문서 `mariadb-galera-backup-verify-guide.md` 참고.

---

## 환경 정보

| 항목 | 값 |
|------|-----|
| 클러스터 노드 | LGEDK8SCMP01V, LGEDK8SCMP02V, LGEDK8SCMP03V (실제 호스트명으로 교체) |
| MariaDB 버전 | 10.11.16 |
| 백업 위치 | `/bkup001/dump/` |
| 데이터 디렉터리 | `/var/lib/mysql/` |
| MariaDB 서비스 | `mariadb` |
| 백업 timer | `mariadb-backup-dump.timer` |

> ⚠️ 명령어 실행 중 묻는 `Enter password:` 는 모두 **MariaDB root 비밀번호** 입니다 (OS root 아님).

---

## 복구 흐름

```
1. 복구 전 준비  →  2. 모든 노드 정지  →  3. 부트스트랩 노드 초기화
                                                ↓
                  6. 검증  ←  5. 나머지 노드 join  ←  4. 백업 import
```

소요 시간: 데이터 크기에 따라 30분 ~ 2시간.

---

## 1. 복구 전 준비

### 1.1 자동 백업 timer 정지

복구 중 새벽 02:00 자동 백업이 끼어들면 사고로 이어집니다. **반드시 먼저 정지.**

```bash
sudo systemctl stop mariadb-backup-dump.timer
sudo systemctl status mariadb-backup-dump.timer | grep Active
```

**예상 출력**:

```text
   Active: inactive (dead) since Fri 2026-05-15 09:16:00 KST; 2s ago
```

> 복구 완료 후 7장에서 반드시 재가동합니다.

### 1.2 백업 파일 확인

```bash
sudo ls -lah /bkup001/dump/
```

**예상 출력 예시**:

```text
-rw-r-----. 1 mysql mysql  795M May 15 02:00 mariadb_full_20260515_020003.sql.gz
-rw-r-----. 1 mysql mysql  792M May 14 02:00 mariadb_full_20260514_020001.sql.gz
...
```

복구에 사용할 파일을 정합니다 (보통 가장 최근 정상 백업):

```bash
TARGET_BACKUP=/bkup001/dump/mariadb_full_20260515_020003.sql.gz
echo "사용할 백업: ${TARGET_BACKUP}"
```

### 1.3 백업 파일 무결성 검증

```bash
sudo gzip -t "${TARGET_BACKUP}" && echo "gzip OK" || echo "gzip FAILED"
```

**예상 출력**:

```text
gzip OK
```

> ⚠️ `gzip FAILED` 면 해당 파일 사용 금지. 한 단계 이전 백업으로 재시도.

### 1.4 백업 사본 보관 (필수)

복구 도중 원본이 손상되거나 덮어쓰일 위험을 차단합니다.

```bash
sudo cp "${TARGET_BACKUP}" /var/tmp/restore_source.sql.gz
sudo ls -lh /var/tmp/restore_source.sql.gz
```

**이후 모든 복구 명령은 이 사본을 사용합니다.**

### 1.5 백업 내용 미리보기 (선택)

복구 전 백업에 어떤 DB 가 들어있는지 확인:

```bash
sudo zcat /var/tmp/restore_source.sql.gz \
  | grep "^-- Current Database:" \
  | head -30
```

**예상 출력 예시**:

```text
-- Current Database: `mysql`
-- Current Database: `app_db`
-- Current Database: `log_db`
```

복구하려는 DB 가 포함되어 있는지 확인합니다.

---

## 2. 모든 노드 MariaDB 정지

각 노드에서 실행합니다. 순서는 상관없고, 가능한 빨리 세 노드 모두 정지시킵니다.

```bash
# db-node-1, db-node-2, db-node-3 각각에서
sudo systemctl stop mariadb
sudo systemctl status mariadb | grep Active
```

**예상 출력**:

```text
   Active: inactive (dead) since Fri 2026-05-15 09:20:00 KST; 3s ago
```

세 노드 모두 `inactive (dead)` 인 것을 확인합니다.

---

## 3. 부트스트랩 노드 초기화

부트스트랩 노드 1대를 정합니다 (보통 db-node-1).

**부트스트랩 노드에서만** 실행:

```bash
# 기존 데이터 디렉터리를 백업으로 옮김 (삭제 아님 — 만약을 위해 보존)
sudo mv /var/lib/mysql /var/lib/mysql.bak.$(date +%Y%m%d_%H%M%S)
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql
sudo chmod 750 /var/lib/mysql
ls -ld /var/lib/mysql
```

**예상 출력**:

```text
drwxr-x---. 2 mysql mysql 6 May 15 09:22 /var/lib/mysql
```

> ⚠️ `mv` 한 백업 디렉터리 (`/var/lib/mysql.bak.*`) 는 복구 성공 확인까지 **절대 삭제 금지**. 7장 정리 단계에서 처리합니다.

---

## 4. 부트스트랩 + 백업 import

### 4.1 부트스트랩으로 기동

**부트스트랩 노드에서**:

```bash
sudo galera_new_cluster
sleep 5
sudo systemctl status mariadb | grep Active
```

**예상 출력**:

```text
   Active: active (running) since Fri 2026-05-15 09:24:00 KST; 5s ago
```

확인:

```bash
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

**예상 출력**:

```text
| wsrep_cluster_size        | 1      |
| wsrep_local_state_comment | Synced |
```

`cluster_size = 1` 정상 (아직 부트스트랩 노드만 떠 있음).

### 4.2 백업 import

```bash
sudo zcat /var/tmp/restore_source.sql.gz | sudo mysql -u root -p
```

비밀번호 입력 후 import 시작.

**진행 중 주의사항**:

- 출력은 거의 없습니다 (조용히 진행)
- 데이터 크기에 따라 수 분 ~ 수십 분 소요
- **절대 Ctrl+C 누르지 마세요**

진행 상황 모니터링이 필요하면 **별도 터미널** 에서:

```bash
watch -n 5 'sudo du -sh /var/lib/mysql'
```

데이터 디렉터리 용량이 증가하면 정상 진행 중.

### 4.3 import 결과 1차 확인

```bash
sudo mysql -u root -p -e "SHOW DATABASES;"
```

**예상 출력**: 복구된 DB 목록이 보여야 합니다.

```text
+--------------------+
| Database           |
+--------------------+
| app_db             |
| information_schema |
| log_db             |
| mysql              |
| performance_schema |
| sys                |
+--------------------+
```

1.5 절에서 확인한 DB 목록이 모두 들어있는지 비교합니다.

---

## 5. 나머지 노드 순차 join

### 5.1 db-node-2 기동

**db-node-2 에서**:

```bash
# 기존 데이터 디렉터리도 보존 후 비우기
sudo mv /var/lib/mysql /var/lib/mysql.bak.$(date +%Y%m%d_%H%M%S)
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql
sudo chmod 750 /var/lib/mysql

sudo systemctl start mariadb
```

**기동 후 SST(State Snapshot Transfer) 가 자동으로 시작됩니다.** 부트스트랩 노드에서 데이터를 받아오는 과정이며 데이터 크기에 따라 시간이 걸립니다.

상태 확인 (Synced 될 때까지 30초 간격으로 반복):

```bash
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

**예상 진행 순서**:

```text
Joining → Joined → Synced
```

`Synced` 가 나오면 다음 노드로.

### 5.2 db-node-3 기동

**db-node-3 에서** 5.1 과 동일하게:

```bash
sudo mv /var/lib/mysql /var/lib/mysql.bak.$(date +%Y%m%d_%H%M%S)
sudo mkdir -p /var/lib/mysql
sudo chown mysql:mysql /var/lib/mysql
sudo chmod 750 /var/lib/mysql

sudo systemctl start mariadb
```

Synced 확인:

```bash
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

---

## 6. 복구 후 검증

### 6.1 클러스터 최종 확인

**아무 노드에서**:

```bash
sudo mysql -u root -p -e "
SHOW STATUS LIKE 'wsrep_cluster_size';
SHOW STATUS LIKE 'wsrep_cluster_status';
SHOW STATUS LIKE 'wsrep_local_state_comment';
"
```

✅ **통과 기준**:

```text
| wsrep_cluster_size        | 3       |
| wsrep_cluster_status      | Primary |
| wsrep_local_state_comment | Synced  |
```

세 노드 모두에서 같은 결과가 나와야 합니다.

### 6.2 데이터 확인

```bash
# DB 별 테이블 개수
sudo mysql -u root -p -e "
SELECT table_schema, COUNT(*) AS table_count
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema', 'performance_schema')
GROUP BY table_schema;
"

# 주요 테이블의 행 수 (필요한 만큼 반복)
sudo mysql -u root -p -e "SELECT COUNT(*) FROM <DB>.<주요_테이블>;"
```

장애 발생 직전 수치와 비교하여 합리적인지 확인합니다.

> ⚠️ 백업이 새벽 02:00 기준이므로 **그 이후 ~ 장애 시점 사이의 데이터는 손실**됩니다. 이는 정상이며 백업 정책(매일 1회)에 따른 결과입니다.

### 6.3 애플리케이션 연결 테스트

애플리케이션이 정상 동작하는지 확인:

```text
□ 애플리케이션 → DB 연결 성공
□ 주요 화면/기능 정상 동작
□ 로그인, 조회, 입력 등 기본 시나리오 통과
```

---

## 7. 마무리

### 7.1 자동 백업 timer 재가동 (필수)

```bash
sudo systemctl start mariadb-backup-dump.timer
sudo systemctl list-timers --all | grep mariadb
```

**예상 출력**:

```text
NEXT                        LEFT    UNIT
Sat 2026-05-16 02:00:00 KST 16h     mariadb-backup-dump.timer
```

`NEXT` 가 다음 날 02:00 으로 잡혀 있어야 정상.

### 7.2 정리 (24시간 후 권장)

복구가 안정적이라고 확인된 후, 아래 파일들을 정리합니다:

```bash
# 데이터 디렉터리 백업 (각 노드)
sudo ls -ld /var/lib/mysql.bak.*
sudo rm -rf /var/lib/mysql.bak.<타임스탬프>   # 충분히 확인 후 실행

# 복구 작업용 사본
sudo rm -f /var/tmp/restore_source.sql.gz
```

> ⚠️ 정리는 **최소 24시간 모니터링 후** 진행하세요. 그 사이 이상이 발견되면 8장 롤백이 가능합니다.

---

## 8. 롤백 (복구가 잘못된 경우)

3장에서 `mv` 로 보존한 `/var/lib/mysql.bak.<타임스탬프>` 디렉터리를 사용해 원래 상태로 되돌립니다.

```bash
# 1. 모든 노드 MariaDB 정지
sudo systemctl stop mariadb   # 각 노드

# 2. 각 노드: 새로 만든 디렉터리 제거 후 원본 복원
sudo rm -rf /var/lib/mysql
sudo mv /var/lib/mysql.bak.<원래_타임스탬프> /var/lib/mysql

# 3. 부트스트랩 노드부터 재기동
sudo galera_new_cluster      # 부트스트랩 노드

# 4. 나머지 노드 순차 기동
sudo systemctl start mariadb   # 노드 2, 3 순서대로
```

각 노드 Synced 확인까지 4.1 / 5장 절차와 동일하게 진행합니다.

---

## 9. 트러블슈팅

| 증상 | 단계 | 해결 |
|------|------|------|
| `gzip: invalid magic` | 1.3 | 백업 파일 손상. 이전 날짜 백업으로 재시도 |
| `ERROR 1045: Access denied for user 'root'` | 전체 | MariaDB root 비밀번호 오류. 비밀번호 재확인 |
| `galera_new_cluster` 후 다른 노드 join 안 됨 | 5.1 / 5.2 | 부트스트랩 노드의 방화벽/네트워크 확인 (4567, 4568, 4444 포트) |
| `wsrep_local_state_comment` 가 `Joining` 에서 멈춤 | 5.1 / 5.2 | SST 진행 중. 큰 데이터는 수십 분 걸릴 수 있음. `sudo tail -f /var/log/mariadb/mariadb.log` 로 확인 |
| import 가 비정상적으로 느림 | 4.2 | NFS 지연 가능성. `df -h /bkup001` 확인. 사본을 로컬 디스크로 옮기는 것 고려 (1.4 의 `/var/tmp/` 가 로컬이면 이미 OK) |
| import 중 디스크 풀 | 4.2 | `/var/lib/mysql` 용량 부족. import 중단 → 8장 롤백 → 디스크 확보 후 재시도 |
| `Backup End` 메시지 없는 백업 파일 | 1.3 통과 후 발견 | import 가 도중에 끊겼던 백업일 수 있음. 이전 날짜 백업으로 재시도 |

### 9.1 로그 위치

| 로그 | 위치 |
|------|------|
| MariaDB 에러 로그 | `/var/log/mariadb/mariadb.log` |
| MariaDB 저널 | `sudo journalctl -u mariadb -n 200` |
| 백업 작업 로그 | `/bkup001/logs/dump_*.log` |

---

## 부록: 자주 쓰는 명령어

### 클러스터 상태 한눈에

```bash
sudo mysql -u root -p -e "
SHOW STATUS LIKE 'wsrep_cluster_size';
SHOW STATUS LIKE 'wsrep_cluster_status';
SHOW STATUS LIKE 'wsrep_local_state_comment';
SHOW STATUS LIKE 'wsrep_ready';
"
```

### 디스크 확인

```bash
df -h /bkup001 /var/lib/mysql /var/tmp
sudo du -sh /var/lib/mysql /bkup001/dump
```

### MariaDB 서비스 제어

```bash
sudo systemctl status mariadb
sudo systemctl stop   mariadb
sudo systemctl start  mariadb            # 일반 시작 (기존 클러스터에 join)
sudo galera_new_cluster                   # 부트스트랩 시작 (첫 노드 전용)
```

---

## 체크리스트

```text
□ 1.1  timer 정지
□ 1.2  사용할 백업 파일 확인
□ 1.3  gzip 무결성 검증 통과
□ 1.4  사본 보관 (/var/tmp/restore_source.sql.gz)
□ 2    모든 노드 mariadb 정지
□ 3    부트스트랩 노드 데이터 디렉터리 초기화
□ 4.1  galera_new_cluster 기동, cluster_size=1 + Synced
□ 4.2  백업 import 완료
□ 4.3  SHOW DATABASES 결과 정상
□ 5.1  db-node-2 join, Synced
□ 5.2  db-node-3 join, Synced
□ 6.1  cluster_size=3, Primary, 모든 노드 Synced
□ 6.2  데이터 행 수 확인
□ 6.3  애플리케이션 정상 동작
□ 7.1  timer 재가동, 다음 NEXT 가 다음날 02:00
□ 7.2  24시간 후 정리 (백업 디렉터리, 사본 파일)
```

---

## 변경 이력

| 일자 | 버전 | 변경 내용 |
|------|------|----------|
| 2026-05-15 | 1.0 | 최초 작성. 덤프 import 중심의 클러스터 전체 복구 절차 |
