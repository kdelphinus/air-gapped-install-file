# MariaDB Galera Cluster 재부팅 운영 가이드

> **대상 환경**: Rocky Linux 9.6 + MariaDB **10.11.16** Galera Cluster (3-node, RPM 직접 설치)
> **작성일**: 2026-05-08
> **참고 가이드**:
>
> - [galera-cluster-guide.md](./galera-cluster-guide.md) — 신규 구축
> - [galera-cluster-guide.md Phase 6](./galera-cluster-guide.md) — Full Crash Recovery
> - [galera-backup-simple-guide.md](./galera-backup-simple-guide.md) — 매일 dump + 7일 보관

본 문서는 운영 중인 Galera 3-node 클러스터에서 **계획 재부팅 / 비계획 재부팅 / 전체 정전 복구** 시 따라야 할 절차입니다.
Galera 는 K8s 와 달리 **노드 간 상태 동기화·quorum·gcache·`safe_to_bootstrap` 플래그** 가 직접 운영자에게 노출되므로
순서를 어기면 데이터 유실(잘못된 노드를 부트스트랩) 또는 Non-Primary 상태로 빠질 수 있습니다.

---

## 목차

1. [개요 — 왜 까다로운가](#1-개요--왜-까다로운가)
2. [재부팅 전 점검](#2-재부팅-전-점검)
3. [시나리오별 절차](#3-시나리오별-절차)
4. [재부팅 후 검증](#4-재부팅-후-검증)
5. [트러블슈팅](#5-트러블슈팅)
6. [체크리스트](#6-체크리스트)

---

## 1. 개요 — 왜 까다로운가

### 1.1 핵심 원칙 5가지

| 원칙 | 의미 |
|------|------|
| **한 번에 1대씩 (Rolling)** | 3대 중 2대 이상이 살아있어야 quorum 유지. 2대 동시 다운 시 살아있는 1대도 Non-Primary 로 빠짐 |
| **Last-down-first-up** | 전체 정지 시 **마지막에 내려간 노드 = 최신 seqno** → 그 노드를 먼저 부트스트랩해야 데이터 유실/전체 SST 회피 |
| **`safe_to_bootstrap=1` 노드만 부트스트랩 가능** | 정상 종료된 마지막 노드는 자동으로 1, 비정상 종료 노드는 0. 0 인 채로 부트스트랩하면 거부됨 (정당한 안전장치) |
| **gcache 크기 vs 다운타임** | 다운타임 동안의 변경량이 gcache 보다 작으면 IST(증분), 크면 SST(전체 복사). SST 는 분~시간 단위 소요 |
| **백업 timer 와 desync 충돌 방지** | 재부팅 전후 백업 timer 가 fire 하면 `wsrep_desync=ON` 잔존 가능성. 점검 창에서 timer 정지 권장 |

### 1.2 용어

- **PC (Primary Component)**: quorum 을 가진 노드들의 집합. 다수파만 PC 가 되어 read/write 가능
- **IST (Incremental State Transfer)**: gcache 에 남아있는 트랜잭션만 적용 → 빠름
- **SST (State Snapshot Transfer)**: 데이터 디렉터리 전체 복사 (mariabackup) → 느림, donor 부하 큼
- **`grastate.dat`**: `<datadir>/grastate.dat`. `seqno`, `safe_to_bootstrap` 보유

---

## 2. 재부팅 전 점검

### 2.1 클러스터 상태 확인 (3대 모두)

```bash
sudo mysql -u root -p <<'SQL'
SHOW STATUS LIKE 'wsrep_cluster_size';        -- 3
SHOW STATUS LIKE 'wsrep_cluster_status';      -- Primary
SHOW STATUS LIKE 'wsrep_local_state_comment'; -- Synced
SHOW STATUS LIKE 'wsrep_ready';               -- ON
SHOW STATUS LIKE 'wsrep_connected';           -- ON
SHOW STATUS LIKE 'wsrep_last_committed';      -- seqno (3대 동일/근접해야 정상)
SQL
```

✅ **통과 기준**: 3대 모두 `Synced`, `cluster_size=3`, `cluster_status=Primary`, `wsrep_last_committed` 가 거의 동일.
하나라도 비정상이면 재부팅 보류 후 원인 해소.

### 2.2 데이터 / 설정 사전 점검

```bash
# 1. wsrep_cluster_address 에 모든 노드 IP/호스트 포함되어 있는지
sudo grep -E 'wsrep_cluster_address|wsrep_node_(name|address)' \
  /etc/my.cnf.d/server.cnf /etc/my.cnf.d/galera.cnf 2>/dev/null

# 2. grastate.dat 위치/seqno
sudo cat /app/mariadb_data/grastate.dat   # datadir 경로는 환경에 맞게

# 3. gcache 크기와 다운타임 추정 (IST 가능 여부)
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_provider_options'\G" \
  | tr ';' '\n' | grep -i 'gcache.size'
# 예: gcache.size = 128M

# 다운타임 동안 예상 write rate 가 gcache 안에 들어와야 IST,
# 아니면 SST. 큰 변경 발생 중이면 점검 시간 미루는 것이 좋다.

# 4. SELinux / firewalld 정책
getenforce
sudo firewall-cmd --list-ports 2>/dev/null   # 3306, 4567, 4568, 4444 확인

# 5. 자동 시작
systemctl is-enabled mariadb
```

### 2.3 지속 연결 / 트랜잭션 영향 평가

```bash
# 활성 연결 / 장기 트랜잭션
sudo mysql -u root -p -e "
  SELECT id, user, host, db, time, state
  FROM information_schema.processlist
  WHERE command != 'Sleep' AND time > 30
  ORDER BY time DESC LIMIT 20;"

# 미커밋 트랜잭션
sudo mysql -u root -p -e "
  SELECT trx_id, trx_state, trx_started, trx_query
  FROM information_schema.innodb_trx;"
```

장기 트랜잭션이 있으면 재부팅 시 롤백 시간이 길어지고, 다른 노드와 종료 순서가 꼬일 수 있습니다.

### 2.4 백업 timer 정지 (재부팅 점검 창 동안)

백업 중 `wsrep_desync=ON` 상태로 노드가 죽으면 OFF 복구가 안 되어, 재부팅 후에도 desync 잔존 가능.

```bash
# 백업 노드에서
sudo systemctl list-timers | grep mariadb
sudo systemctl stop mariadb-backup-dump.timer        # 점검 창 동안 정지
# (점검 종료 후 다시 start)
```

또한 진행 중인 백업이 있으면 종료 대기:

```bash
sudo systemctl status mariadb-backup-dump.service --no-pager
# active (running) 이면 종료까지 대기
```

### 2.5 K8s 애플리케이션 측 영향

DB 가 K8s 워크로드의 backing store 면, 짧은 단절을 견디지 못하는 앱(특히 Spring/Hibernate connection pool, 일부 PHP-FPM)은 `CrashLoopBackOff` 가능. 점검 시간으로 공지하거나 재부팅 후 [Phase 6 4단계 / `kubectl rollout restart`](./galera-cluster-guide.md) 절차로 복구 준비.

---

## 3. 시나리오별 절차

### 3.1 시나리오 A — 단일 노드 계획 재부팅 (Rolling)

가장 일반적이고 안전한 시나리오. 노드 1대씩 순서대로 재부팅.

```bash
# === 노드 N 에서 ===

# 1. (선택) 백업 노드라면 timer 정지 (2.4 참고)

# 2. 정상 종료
sudo systemctl stop mariadb

# 3. 다른 노드에서 cluster_size=2, 여전히 Primary 인지 확인
sudo mysql -u root -p -e "
  SHOW STATUS LIKE 'wsrep_cluster_size';        -- 2
  SHOW STATUS LIKE 'wsrep_cluster_status';      -- Primary"

# 4. 노드 N 재부팅
sudo systemctl reboot

# 5. 부팅 후 자동 시작된 mariadb 가 IST 또는 SST 로 합류
#    (systemctl is-enabled mariadb 가 enabled 라면 자동 시작)
sudo systemctl status mariadb --no-pager
sudo journalctl -u mariadb -n 100 --no-pager | grep -E 'IST|SST|SYNCED|Synced'

# 6. 합류 검증
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"  # Synced
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"          # 3

# 7. 다음 노드로 진행 (반드시 Synced 이후)
```

> ⚠️ **다음 노드 재부팅 전 반드시 `Synced` + `cluster_size=3` 확인.**
> Joining/Donor 상태에서 또 1대 내리면 quorum 손실로 전체 Non-Primary 위험.

### 3.2 시나리오 B — 노드 2대 동시 재부팅 (비권장, 불가피한 경우)

quorum 손실 → 살아있는 1대도 Non-Primary 로 read-only.
**가능하면 시나리오 A 로 분리 진행**. 불가피하면 시나리오 C(전체 정지)로 처리.

### 3.3 시나리오 C — 전체 클러스터 계획 정지 / 시작

운영 종료, 데이터센터 점검 등에서 3대를 모두 내릴 때.

#### 3.3.1 정지 (Last-down 노드 기억)

```bash
# 1. 모든 클라이언트/앱 트래픽 차단 (앱 측, HAProxy, K8s Service 등)

# 2. 한 번에 1대씩 정상 종료
ssh galera-cluster-3 sudo systemctl stop mariadb
ssh galera-cluster-2 sudo systemctl stop mariadb
ssh galera-cluster-1 sudo systemctl stop mariadb   # ← 가장 마지막에 종료

# 3. 마지막에 종료한 노드(galera-cluster-1) 의 grastate.dat 확인
ssh galera-cluster-1 sudo cat /app/mariadb_data/grastate.dat
# safe_to_bootstrap: 1  ← 정상 종료라면 자동으로 1
# seqno: <숫자>          ← -1 이 아니어야 함
```

> **반드시 기록**: 마지막에 정상 종료한 노드 = 다음 부팅 시 부트스트랩할 노드.

#### 3.3.2 시작 (Last-down-first-up)

```bash
# 1. 마지막에 종료한 노드부터 부트스트랩
ssh galera-cluster-1 sudo galera_new_cluster

ssh galera-cluster-1 sudo mysql -u root -p -e "
  SHOW STATUS LIKE 'wsrep_cluster_size';        -- 1
  SHOW STATUS LIKE 'wsrep_cluster_status';      -- Primary
  SHOW STATUS LIKE 'wsrep_local_state_comment'; -- Synced"

# 2. 나머지 노드를 한 번에 1대씩 합류 (일반 systemctl start)
ssh galera-cluster-2 sudo systemctl start mariadb
# Synced 확인
ssh galera-cluster-2 sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"

ssh galera-cluster-3 sudo systemctl start mariadb
# 최종 검증
ssh galera-cluster-1 sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"  # 3

# 3. 앱 트래픽 재개
```

> ⚠️ **`galera_new_cluster` 는 단 1대(첫 번째 노드)에서만.** 다른 노드에서 또 실행하면 별도 클러스터가 떠서 split-brain.

### 3.4 시나리오 D — 비계획 전체 다운 (정전, 동시 크래시)

`safe_to_bootstrap` 이 모두 0 일 가능성이 큼. **데이터 유실 회피를 위해 seqno 비교가 필수**.

[galera-cluster-guide.md Phase 6 (Full Crash Recovery)](./galera-cluster-guide.md) 절차를 따르세요. 핵심 요약:

```bash
# 3대 모두에서 실행하여 seqno 추출
sudo /usr/sbin/mariadbd --wsrep-recover --datadir=/app/mariadb_data
# 로그 마지막 "Recovered position: UUID:seqno" 비교

# seqno 가 가장 큰 노드를 Primary 로 선정
# grastate.dat 의 safe_to_bootstrap 을 1 로 수정
sudo vi /app/mariadb_data/grastate.dat   # safe_to_bootstrap: 0 → 1

# 부트스트랩
sudo galera_new_cluster

# 나머지 노드 합류 (시나리오 C 동일)
```

### 3.5 시나리오 E — 노드 1대만 비정상 재부팅 (다른 2대는 정상)

가장 가벼운 케이스. 부팅 후 자동 시작 → IST 또는 SST 로 합류.

```bash
# 부팅 직후
sudo journalctl -u mariadb -n 200 --no-pager | grep -E 'wsrep|IST|SST|Synced'

# IST 면 수십 초 ~ 분 단위, SST 면 데이터 크기에 비례
# 합류 진행 중인지 (Donor/Desynced/Joiner) 확인
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

자동 시작이 실패한 경우(`safe_to_bootstrap=0` 인 단일 노드가 다른 2대와 통신 못 함 등):

```bash
sudo systemctl status mariadb --no-pager
sudo journalctl -u mariadb -n 100 --no-pager
# wsrep_cluster_address 에 다른 노드들이 정확히 들어있는지 재확인
```

---

## 4. 재부팅 후 검증

### 4.1 클러스터 상태

```bash
# 3대 모두에서
sudo mysql -u root -p <<'SQL'
SHOW STATUS LIKE 'wsrep_cluster_size';        -- 3
SHOW STATUS LIKE 'wsrep_cluster_status';      -- Primary
SHOW STATUS LIKE 'wsrep_local_state_comment'; -- Synced
SHOW STATUS LIKE 'wsrep_ready';               -- ON
SHOW STATUS LIKE 'wsrep_connected';           -- ON
SHOW STATUS LIKE 'wsrep_evs_state';           -- OPERATIONAL
SHOW STATUS LIKE 'wsrep_last_committed';      -- 3대 거의 동일
SHOW STATUS LIKE 'wsrep_desync_count';        -- 0
SHOW VARIABLES LIKE 'wsrep_desync';           -- OFF
SQL
```

### 4.2 합류 방식 확인 (IST 권장 / SST 발생 시 원인 분석)

```bash
sudo journalctl -u mariadb --since '30 minutes ago' --no-pager \
  | grep -iE 'IST|SST|state transfer|streaming|SYNCED'
```

- `IST` 라인이 보이면 정상 (gcache 적중)
- `SST` 가 발생했다면: gcache 부족 또는 다운타임이 길었음 → 정책 검토

### 4.3 쓰기/읽기 동작 검증

```bash
# 어느 노드에서든 INSERT 후 다른 노드에서 즉시 보이는지
NODE_A_INSERT() { sudo mysql -u root -p -h galera-cluster-1 -e "$1"; }
NODE_B_SELECT() { sudo mysql -u root -p -h galera-cluster-2 -e "$1"; }

NODE_A_INSERT "CREATE DATABASE IF NOT EXISTS _reboot_check;
               CREATE TABLE IF NOT EXISTS _reboot_check.t (id INT PRIMARY KEY, ts DATETIME);
               INSERT INTO _reboot_check.t VALUES (UNIX_TIMESTAMP(), NOW());"

NODE_B_SELECT "SELECT * FROM _reboot_check.t ORDER BY id DESC LIMIT 1;"
# 방금 넣은 row 가 보여야 정상

# 정리
NODE_A_INSERT "DROP DATABASE _reboot_check;"
```

### 4.4 백업 timer 재개 / desync 잔존 확인

```bash
# desync 잔존 확인 (재부팅 중 백업이 끼어들었을 가능성)
sudo mysql -u root -p -e "SHOW VARIABLES LIKE 'wsrep_desync';"
# OFF 가 아니면
sudo mysql -u root -p -e "SET GLOBAL wsrep_desync=OFF;"

# 백업 노드에서 timer 재개
sudo systemctl start mariadb-backup-dump.timer
sudo systemctl list-timers | grep mariadb
```

### 4.5 K8s 애플리케이션 복구

```bash
# CrashLoopBackOff 확인
kubectl get pods -A | grep -E 'CrashLoopBackOff|Error'

# 해당 네임스페이스 deployment/sts 재시작
kubectl rollout restart deployment --all -n <namespace>
kubectl rollout restart statefulset --all -n <namespace>

kubectl get pods -A | grep -vE 'Running|Completed'
```

---

## 5. 트러블슈팅

### 5.1 노드가 Joining / Joiner 에서 멈춤

```bash
sudo journalctl -u mariadb -n 200 --no-pager
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

원인별 해결:

| 메시지 | 원인 | 조치 |
|--------|------|------|
| `WSREP_SST: ... mariabackup ... failed` | SST 실패 (donor 부하/네트워크/권한) | mariabackup 사용자 권한 확인, donor 노드 부하 확인, 재시작 |
| `IST receiver ... Failed to open channel` | 4568/TCP 차단 | firewall-cmd, 라우팅 점검 |
| `gcs.cc: ... can't reach` | 4567/TCP·UDP 차단 또는 wsrep_cluster_address 오타 | 방화벽, 설정 점검 |

### 5.2 SST 가 IST 대신 발생 (느림)

원인:

- gcache 부족 (`wsrep_provider_options=...gcache.size=...` 가 작음)
- 다운타임이 너무 김
- gcache 파일 (`<datadir>/galera.cache`) 가 손실/삭제됨

**즉시 조치**: SST 가 정상 완료되도록 기다린다 (중간에 끊으면 SST 재시도 — 더 느려짐).

**향후 예방**: gcache 크기를 최근 1주일 write 량 + 여유분 으로 증설.

### 5.3 `safe_to_bootstrap: 0` 라 부트스트랩 거부됨

```text
[ERROR] WSREP: It may not be safe to bootstrap the cluster from this node.
```

판단 절차:

```bash
# 3대 모두에서 seqno 추출
sudo /usr/sbin/mariadbd --wsrep-recover --datadir=/app/mariadb_data 2>&1 \
  | grep 'Recovered position'
```

- **seqno 가 가장 큰 노드** 가 데이터 최신 → 그 노드의 `grastate.dat` 에서 `safe_to_bootstrap: 0 → 1` 수정 후 부트스트랩
- seqno 가 모두 `-1` 이면 정상 종료 정보가 없는 것 — `--wsrep-recover` 결과를 우선

### 5.4 Non-Primary 상태 (read-only)

```bash
sudo mysql -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_status';"
# Non-Primary 출력
```

원인: quorum 손실 (네트워크 분단, 2대 이상 동시 다운).

처리:

```bash
# 1. 다른 노드 복구로 quorum 회복이 1순위
# 2. 어쩔 수 없이 강제 Primary 승격 (남은 1대만 살아있는 경우)
sudo mysql -u root -p -e "SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';"

# 이후 다른 노드를 합류시킬 때는 SST 가 발생할 가능성이 높음
```

> ⚠️ `pc.bootstrap=YES` 는 **분단된 다른 그룹의 데이터를 버리는 결정**입니다.
> 반드시 해당 그룹이 정말 죽었음을 확인하고 사용.

### 5.5 wsrep_desync=ON 잔존

재부팅 중 백업 작업이 desync OFF 못 하고 끝난 경우.

```bash
sudo mysql -u root -p -e "SET GLOBAL wsrep_desync=OFF;"
```

근본 대책: 점검 창 동안 백업 timer 정지 (2.4 참고).

### 5.6 `Read-only file system` 으로 부트스트랩 실패

RHEL 9 systemd 보안 정책 (`ProtectSystem=full`) 가 커스텀 datadir 쓰기를 차단.

[galera-cluster-guide.md 부록 A-1](./galera-cluster-guide.md) 의 override 적용:

```bash
sudo mkdir -p /etc/systemd/system/mariadb.service.d
sudo tee /etc/systemd/system/mariadb.service.d/override.conf <<'EOF'
[Service]
ProtectSystem=off
ProtectHome=off
PrivateTmp=false
ReadWritePaths=/app/mariadb_data
EOF
sudo systemctl daemon-reload
sudo systemctl restart mariadb
```

### 5.7 K8s 앱 CrashLoopBackOff 지속

```bash
kubectl logs <pod> --previous | tail -50

# DB 연결 풀 초기화 안 되는 앱 → rollout restart 가 가장 확실
kubectl rollout restart deployment/<name> -n <ns>
```

PVC 가 NFS 기반인 경우 NFS 마운트가 풀렸는지도 확인:

```bash
kubectl get pv,pvc -A | grep -vE 'Bound|Available'
```

---

## 6. 체크리스트

### 6.1 재부팅 전

- [ ] 3대 모두 `Synced` / `cluster_size=3` / `cluster_status=Primary`
- [ ] `wsrep_last_committed` 3대 거의 동일 (큰 격차 없음)
- [ ] `wsrep_cluster_address` / 방화벽(3306, 4567, 4568, 4444) / `wsrep_node_name` 검증
- [ ] gcache 크기 vs 예상 다운타임 평가 (IST 가능 여부)
- [ ] 장기 트랜잭션 / 미커밋 트랜잭션 없음
- [ ] 백업 timer 정지 + 진행 중 백업 종료 대기
- [ ] (시나리오 C) 마지막에 정지할 노드 결정 및 기록
- [ ] K8s 앱 영향 공지 / rollout restart 준비

### 6.2 재부팅 중 (노드별)

- [ ] (Rolling) 정상 종료 → 다른 2대 `cluster_size=2` + `Primary` 확인
- [ ] 부팅 후 mariadb 자동 시작 또는 수동 시작 성공
- [ ] 합류 후 `Synced` 도달 확인
- [ ] 다음 노드 진행 전 `cluster_size=3`, 모두 `Synced`

### 6.3 재부팅 후 (전체)

- [ ] `wsrep_cluster_size=3`, 모두 `Synced` / `Primary`
- [ ] `wsrep_desync=OFF`
- [ ] IST 로 합류했는지 로그 확인 (SST 시 원인 기록)
- [ ] 노드 간 INSERT/SELECT 동기화 검증
- [ ] 백업 timer 재개 + `list-timers` 확인
- [ ] K8s 앱 정상화 (`CrashLoopBackOff` 없음)
- [ ] 정전 / 비계획 재부팅이었다면 모니터링·로그 보존

---

> **운영 팁**:
>
> - 점검 창은 **20–30분 / 노드** (Rolling), 전체 정지/시작은 **45–90분**.
> - 비정상 다운 후 복구는 [galera-cluster-guide.md Phase 6](./galera-cluster-guide.md) 와 본 가이드 5장을 함께 참조.
> - `safe_to_bootstrap` 을 **임의로 1 로 바꾸지 말 것** — 반드시 `--wsrep-recover` 로 seqno 비교 후 결정.
> - 점검 직후 백업 1회 수동 실행으로 정상성 재확인 권장:
>
>   ```bash
>   sudo -u mysql /opt/mariadb-backup/backup-dump.sh
>   ```
