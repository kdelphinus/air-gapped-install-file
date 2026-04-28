# MariaDB 10.11 Galera Cluster 구성 가이드 (온라인)

Rocky Linux 9.6 환경에서 MariaDB 10.11 Galera Cluster 3중화를 구성하는 절차입니다.
인터넷이 가능한 환경 기준으로 MariaDB 공식 저장소(`yum.mariadb.org`)에서 RPM을 직접 받습니다.
폐쇄망 절차는 [galera-cluster-guide.md](galera-cluster-guide.md), 단일 노드 설치는 [install-guide.md](install-guide.md)
를 참조하세요.

## 전제 조건

- Rocky Linux 9.6 서버 3대 (인터넷 가능)
- 일반 사용자 계정 (sudo 권한 필수)
- 외부 저장소(`yum.mariadb.org`) 접근 가능
- 노드 간 4567/4568/4444/3306 포트 양방향 통신 가능

## 클러스터 구성 정보

| 호스트명 | 역할 | IP | 비고 |
| :--- | :--- | :--- | :--- |
| galera-cluster-1 | Primary (Bootstrap) | `IP_1` | 최초 클러스터 시작 |
| galera-cluster-2 | Member | `IP_2` | |
| galera-cluster-3 | Member | `IP_3` | |

- **Cluster Name:** `my_galera_svc`
- **SST Method:** mariabackup

---

## Phase 1: OS 및 네트워크 설정 (3대 공통)

### 1-1. 호스트 파일 등록

IP 확정 후 3대 서버 모두 동일하게 수정합니다.

```bash
sudo vi /etc/hosts
```

```text
192.168.XXX.XX   galera-cluster-1
192.168.XXX.XX   galera-cluster-2
192.168.XXX.XX   galera-cluster-3
```

### 1-2. 호스트네임 변경

각 서버 번호에 맞게 실행합니다.

```bash
sudo hostnamectl set-hostname galera-cluster-1
```

### 1-3. SELinux Permissive 전환

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

### 1-4. 방화벽 포트 오픈

```bash
sudo firewall-cmd --permanent --add-port={3306,4567,4568,4444}/tcp
sudo firewall-cmd --permanent --add-port=4567/udp
sudo firewall-cmd --reload
```

| 포트 | 프로토콜 | 용도 |
| :--- | :--- | :--- |
| 3306 | TCP | MySQL 클라이언트 접속 |
| 4567 | TCP/UDP | Galera 클러스터 통신 (gcomm) |
| 4568 | TCP | IST (Incremental State Transfer) |
| 4444 | TCP | SST (State Snapshot Transfer) |

### 1-5. 시간 동기화 (chrony)

Galera 는 노드 간 시계 차이에 민감하므로 NTP 동기화를 강제합니다.

```bash
sudo dnf install -y chrony
sudo systemctl enable --now chronyd
chronyc sources
```

---

## Phase 2: MariaDB 공식 저장소 등록 및 설치 (3대 공통)

### 2-1. Rocky 9 내장 모듈 비활성화

Rocky 9 기본 AppStream 의 MariaDB 10.5 와 충돌을 방지합니다.

```bash
sudo dnf module disable mariadb -y
```

`missing groups or modules: mariadb` 메시지는 무시 가능합니다.

### 2-2. MariaDB 공식 저장소 등록

10.11 LTS 라인을 등록합니다.

```bash
cat <<'EOF' | sudo tee /etc/yum.repos.d/mariadb.repo
[mariadb]
name = MariaDB 10.11
baseurl = https://rpm.mariadb.org/10.11/rhel/$releasever/$basearch
gpgkey = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck = 1
enabled = 1
module_hotfixes = 1
EOF

# 캐시 갱신 및 검색 확인
sudo dnf clean all
sudo dnf makecache
dnf info MariaDB-server | head -20
```

> `module_hotfixes = 1` 은 AppStream 모듈 시스템이 비공식 RPM 을 가리지 않도록 강제하는
> 옵션으로, MariaDB 공식 저장소 사용 시 필수입니다.

### 2-3. 서버·클라이언트·Galera·백업 패키지 설치

```bash
sudo dnf install -y \
    MariaDB-server \
    MariaDB-client \
    MariaDB-backup \
    galera-4
```

> MariaDB 공식 저장소의 패키지명은 대문자(`MariaDB-server`)이며, Rocky AppStream 의
> `mariadb-server` (소문자) 와 다른 패키지입니다. 동시에 설치되지 않도록 2-1 의 모듈 비활성화가
> 선행되어야 합니다.

### 2-4. 서비스 등록 (시작하지 않음)

```bash
sudo systemctl enable mariadb
```

### 2-5. 데이터 디렉토리 구성 (경로 변경 시)

기본 경로(`/var/lib/mysql`)를 사용한다면 이 단계는 건너뜁니다.

```bash
# 디렉토리 생성
sudo mkdir -p /app/mariadb_data

# 소유권 설정 (mysql 계정은 RPM 설치 시 자동 생성)
sudo chown -R mysql:mysql /app/mariadb_data
sudo chmod 750 /app/mariadb_data

# DB 초기화 (커스텀 경로에는 시스템 테이블이 없으므로 필수)
sudo mariadb-install-db --user=mysql --datadir=/app/mariadb_data
```

> 10.5 부터 `mysql_install_db` 는 `mariadb-install-db` 로 rename 되었으며, 10.11 에서도
> 이전 이름은 alias 로 동작합니다.

---

## Phase 3: Galera 설정 파일 작성 (3대 공통)

`/etc/my.cnf.d/01-galera.cnf` 파일을 생성합니다. 서버마다 `wsrep_node_address` 와
`wsrep_node_name` 값을 변경해야 합니다.

```bash
sudo vi /etc/my.cnf.d/01-galera.cnf
```

```ini
[mariadb]
# --- 기본 설정 ---
# 데이터 경로를 옮길 때만 사용
# datadir=/app/mariadb_data
bind-address=0.0.0.0
default_storage_engine=InnoDB
binlog_format=ROW
innodb_autoinc_lock_mode=2

# --- 튜닝 ---
lower_case_table_names=1
max_connections=1000
sql_mode="STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"

# --- Galera Provider ---
wsrep_on=ON
wsrep_provider=/usr/lib64/galera-4/libgalera_smm.so

# --- 클러스터 공통 (3대 동일) ---
wsrep_cluster_name="my_galera_svc"
wsrep_cluster_address="gcomm://IP_1,IP_2,IP_3"

# --- 노드별 고유 설정 (서버마다 수정!) ---
wsrep_node_address="본인_서버_IP"
wsrep_node_name="galera-cluster-X"

# --- 동기화 ---
wsrep_sst_method=mariabackup
```

서버별 변경 요약:

| 서버 | wsrep_node_address | wsrep_node_name |
| :--- | :--- | :--- |
| 1번 | `IP_1` | `galera-cluster-1` |
| 2번 | `IP_2` | `galera-cluster-2` |
| 3번 | `IP_3` | `galera-cluster-3` |

> SST 방식이 `mariabackup` 이므로 모든 노드에 `MariaDB-backup` 패키지가 설치되어 있어야
> 합니다 (Phase 2-3 에서 설치 완료).

---

## Phase 4: 클러스터 기동 (순서 준수)

### 4-1. galera-cluster-1 (Bootstrap)

반드시 1번 서버에서 가장 먼저 실행합니다.

```bash
sudo galera_new_cluster

# 클러스터 사이즈 확인 (1이어야 함)
sudo mariadb -u root -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

### 4-2. galera-cluster-2

```bash
sudo systemctl start mariadb

# 클러스터 사이즈 확인 (2로 증가)
sudo mariadb -u root -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

### 4-3. galera-cluster-3

```bash
sudo systemctl start mariadb

# 최종 확인 (3이어야 함)
sudo mariadb -u root -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

---

## Phase 5: 검증

### 5-1. 복제 테스트

1번 노드에서 DB 를 생성하고 3번 노드에서 확인합니다.

```bash
# Node 1
sudo mariadb -u root -e "CREATE DATABASE galera_test_db;"

# Node 3
sudo mariadb -u root -e "SHOW DATABASES;"
```

`galera_test_db` 가 보이면 3중화 성공입니다.

### 5-2. K8s 노드 연결 (필요 시)

다른 노드의 K8s 에서 접속해야 할 경우 IP 허용 규칙을 추가합니다.

```sql
-- 전용 계정 생성 ('20.%'는 20.x.x.x 대역 전체 허용)
CREATE USER 'k8s_app_user'@'20.%' IDENTIFIED BY 'K8s_Passw0rd!';
GRANT ALL PRIVILEGES ON *.* TO 'k8s_app_user'@'20.%';
FLUSH PRIVILEGES;
```

K8s 에서 연결 확인:

```bash
# 임시 파드 생성
kubectl run tmp-shell --rm -it \
  --image=docker.io/library/busybox:latest \
  --restart=Never -- sh

# 파드 내부에서 연결 테스트
telnet <IP_1> 3306
```

---

## Phase 6: 장애 복구 (Full Crash Recovery)

모든 노드가 비정상 종료되어 서비스가 전면 중단된 경우의 복구 절차입니다.

> 본 가이드는 `/app/mariadb_data` 경로를 기준으로 작성되었습니다. 실제 서버의 데이터
> 경로가 다를 수 있으므로 명령어 실행 전 반드시 확인하세요.

### 6-1. 복구 논리

- **최신 트랜잭션 판별:** 모든 노드가 다운된 경우, 가장 최신 트랜잭션(`seqno`)을 보유한 노드를
  찾아 Primary 로 승격시켜야 데이터 유실 및 전체 동기화(SST)를 방지할 수 있습니다.
- **커스텀 경로 스캔:** 데이터가 커스텀 경로에 저장된 경우, `--datadir` 옵션을 반드시
  명시해야 합니다.

### 6-2. 복구 절차

**1단계: Primary 노드 판별**

3대 서버 모두에서 MariaDB 프로세스가 없는지 확인한 후 트랜잭션 번호를 추출합니다.

```bash
# 잔여 프로세스 확인
ps -ef | grep mysql

# 복구 위치(seqno) 추출
sudo /usr/sbin/mariadbd --wsrep-recover --datadir=/app/mariadb_data
```

로그 마지막의 `Recovered position: UUID:seqno` 값 중 **seqno 가 가장 큰 노드**를 Primary 로
선정합니다. 숫자가 같다면 `grastate.dat` 의 `safe_to_bootstrap: 1` 인 노드를 선택합니다.

**2단계: Primary 노드 부트스트랩**

```bash
# grastate.dat에서 safe_to_bootstrap: 1로 변경
sudo vi /app/mariadb_data/grastate.dat

# 클러스터 초기화 (Primary 노드에서만)
sudo galera_new_cluster

# 검증 (Size = 1)
sudo mariadb -u root -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

**3단계: 나머지 노드 합류**

나머지 노드에서 하나씩 서비스를 시작합니다.

```bash
sudo systemctl start mariadb

# 최종 검증 (Size = 3)
sudo mariadb -u root -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

**4단계: K8s 애플리케이션 파드 정상화**

DB 접속 실패로 `CrashLoopBackOff` 상태인 파드들을 재시작합니다.

```bash
kubectl rollout restart deployment --all -n [네임스페이스]
```

### 6-3. 복구 체크리스트

| 완료 | 분류 | 점검 대상 및 명령어 | 기준 / 비고 |
| :---: | :--- | :--- | :--- |
| [ ] | **사전 조사** | `ps -ef \| grep mysql` | 3대 모두 잔여 프로세스 없음 |
| [ ] | **상태 추출** | `--wsrep-recover --datadir=[경로]` | 3대 중 `seqno` 최고값 판별 완료 |
| [ ] | **부트스트랩** | Primary: `sudo galera_new_cluster` | `wsrep_cluster_size` = 1 |
| [ ] | **노드 합류** | 나머지: `sudo systemctl start mariadb` | `wsrep_cluster_size` = 3 |
| [ ] | **파드 복구** | `kubectl rollout restart deployment` | 앱 파드 `Running` 확인 |

---

## Phase 7: CVE 패치 / Minor 업그레이드

온라인 환경에서는 동일 라인(10.11.x) 내 patch 만 dnf 로 직접 적용할 수 있습니다.
**노드별 순차(rolling) 업그레이드**가 원칙입니다.

```bash
# 한 노드씩 진행
sudo systemctl stop mariadb
sudo dnf update -y --disablerepo='*' --enablerepo=mariadb \
    MariaDB-server MariaDB-client MariaDB-backup galera-4
sudo systemctl start mariadb

# 클러스터 재합류 확인
sudo mariadb -u root -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
# Synced 출력 확인 후 다음 노드 진행
```

> 10.11 → 10.x (다른 minor) 또는 메이저 업그레이드는 SST 호환성 검증과 함께
> 별도 절차로 수행해야 하며, 본 가이드 범위 밖입니다.

---

## 부록: RHEL 9 트러블슈팅

커스텀 경로(`/app/mariadb_data`) 사용 시 RHEL 9 보안 정책으로 인해 발생할 수 있는
이슈입니다.

### A-1. Systemd 보안 정책 충돌 (Read-only file system)

**증상:** `galera_new_cluster` 실행 시 `Errcode: 30 "Read-only file system"` 발생

**원인:** RHEL 9 의 `ProtectSystem=full` 정책이 시스템 경로에 대한 쓰기를 차단

**해결:**

```bash
# Override 디렉토리 생성 및 설정 작성
sudo mkdir -p /etc/systemd/system/mariadb.service.d

sudo tee /etc/systemd/system/mariadb.service.d/override.conf <<'EOF'
[Service]
ProtectSystem=off
ProtectHome=off
PrivateTmp=false
ReadWritePaths=/app/mariadb_data
EOF

# 설정 반영
sudo systemctl daemon-reload
sudo systemctl restart mariadb
```

### A-2. SELinux 권한 차단

**증상:** 파일 시스템 권한이 올바름에도 Permission Denied 발생 또는 서비스 시작 실패

**원인:** 커스텀 경로에 `mysqld_db_t` 보안 컨텍스트가 없음

**해결:**

```bash
# policycoreutils-python-utils 가 없으면 먼저 설치
sudo dnf install -y policycoreutils-python-utils

# MariaDB 데이터 컨텍스트 부여
sudo semanage fcontext -a -t mysqld_db_t "/app/mariadb_data(/.*)?"

# 실제 파일 시스템에 적용
sudo restorecon -R -v /app/mariadb_data

# 정책 확인
ls -Zd /app/mariadb_data
```

### A-3. HA(VIP) 구성 시 주의사항 (데이터 파손 방지)

Keepalived 등으로 VIP 를 구성할 때 주의할 점입니다.

- **Shared-Nothing 원칙 준수:** Galera Cluster 는 각 노드가 독립적인 스토리지를 가져야
  합니다. 동일한 SAN/iSCSI 디스크를 여러 노드에 동시 마운트하면 파일 시스템 메타데이터가
  파손되어 OS 가 디스크를 `Read-only` 로 잠급니다.
- **해결책:** 반드시 노드별 로컬 디스크 또는 독립적인 볼륨을 사용하세요. 클러스터 파일
  시스템(GFS2 등)은 Galera 환경에서 권장되지 않습니다.
- **Failover 점검:** VIP 할당 직후 DB 가 멈춘다면, HA 솔루션이 노드를 격리(Fencing)하고
  있지 않은지 확인하세요.

### A-4. 저장소 등록 후 패키지가 안 보일 때

**증상:** `dnf install MariaDB-server` 시 `No match for argument`

**원인:** AppStream 모듈 시스템이 패키지를 가리고 있음

**해결:**

```bash
# 모듈 비활성화 재확인
sudo dnf module list mariadb
sudo dnf module reset mariadb -y
sudo dnf module disable mariadb -y

# 저장소 우선순위 확인 (mariadb.repo 의 module_hotfixes=1 필수)
grep -A1 module_hotfixes /etc/yum.repos.d/mariadb.repo
```
