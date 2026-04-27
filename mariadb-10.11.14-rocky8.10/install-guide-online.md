# MariaDB 10.11 Galera Cluster 온라인 설치 가이드 (Rocky 8.10)

이 가이드는 Rocky Linux 8.10 환경에서 인터넷이 연결된 상태로 MariaDB 10.11 Galera Cluster를 구성하는 절차를 설명합니다.

## 전제 조건

- Rocky Linux 8.10 서버 3대 (온라인 환경)
- 일반 사용자 계정 (sudo 권한 필수)

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

3대 서버 모두 동일하게 `/etc/hosts` 파일을 수정합니다.

```bash
sudo vi /etc/hosts
```

```text
IP_1   galera-cluster-1
IP_2   galera-cluster-2
IP_3   galera-cluster-3
```

### 1-2. 호스트네임 변경 (필요 시)

기존 호스트네임이 운영 정책상 적합하지 않은 경우에만 변경합니다.
변경 후 셸 프롬프트는 새 세션에서 갱신되므로 재로그인하거나 `exec bash`를 실행하세요.

```bash
# 예: 1번 서버
sudo hostnamectl set-hostname galera-cluster-1
exec bash
```

### 1-3. SELinux 및 방화벽 설정

```bash
# SELinux Permissive 전환
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# 방화벽 포트 오픈
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

---

## Phase 2: MariaDB 온라인 설치 (3대 공통)

### 2-1. MariaDB Repository 추가

공식 MariaDB 10.11 저장소를 설정합니다.
`module_hotfixes=1` 은 Rocky 8 의 modular 시스템(AppStream)이 외부 repo 패키지를
무시하지 않도록 강제하는 옵션으로, `module disable` 만으로는 의존성 해석이 다시
modular 쪽으로 끌려갈 수 있어 함께 명시합니다.

```bash
sudo tee /etc/yum.repos.d/MariaDB.repo <<EOF
[mariadb]
name = MariaDB
baseurl = https://rpm.mariadb.org/10.11/rhel8-amd64
gpgkey = https://rpm.mariadb.org/MariaDB-Server-GPG-KEY
gpgcheck = 1
module_hotfixes = 1
EOF
```

### 2-2. 기본 모듈 비활성화 및 패키지 설치

Rocky 8 내장 MariaDB와의 충돌을 방지하기 위해 모듈을 비활성화하고, 필요한 패키지를 설치합니다.

```bash
# 기본 모듈 비활성화
sudo dnf module disable mariadb -y

# MariaDB 패키지 설치
sudo dnf install -y MariaDB-server MariaDB-client galera-4 MariaDB-backup
```

### 2-3. 서비스 등록 (시작하지 않음)

```bash
sudo systemctl enable mariadb
```

---

## Phase 3: Galera 설정 파일 작성 (3대 공통)

`/etc/my.cnf.d/01-galera.cnf` 파일을 생성합니다. 서버마다 `wsrep_node_address`와 `wsrep_node_name` 값을 변경해야 합니다.

```bash
sudo vi /etc/my.cnf.d/01-galera.cnf
```

```ini
[mariadb]
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

## Phase 5: 보안 초기화 및 검증

### 5-1. mysql_secure_installation (1번 노드에서만 1회)

Galera 는 모든 변경이 자동 동기화되므로 한 노드에서만 실행하면 됩니다.
root 패스워드 설정, 익명 사용자 제거, 원격 root 로그인 차단, test DB 제거를 권장 설정으로 진행합니다.

```bash
sudo mysql_secure_installation
```

### 5-2. 복제 테스트

1번 노드에서 DB를 생성하고 3번 노드에서 확인합니다.

```bash
# Node 1
sudo mariadb -u root -p -e "CREATE DATABASE galera_test_db;"

# Node 3
sudo mariadb -u root -p -e "SHOW DATABASES;"
```

`galera_test_db`가 보이면 3중화 성공입니다.

### 5-3. 외부 애플리케이션 연결 (필요 시)

다른 네트워크 대역(예: K8s 노드)에서 접속해야 할 경우 IP 허용 규칙을 추가합니다.

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

> 본 가이드는 기본 데이터 경로(`/var/lib/mysql`)를 기준으로 작성되었습니다.
> 커스텀 경로(부록 A 참조)를 사용하는 경우 `--datadir` 값을 실제 경로로 교체하세요.

### 6-1. 복구 논리

- **최신 트랜잭션 판별:** 모든 노드가 다운된 경우, 가장 최신 트랜잭션(`seqno`)을 보유한 노드를 Primary로 승격해야 데이터 유실 및 전체 동기화(SST)를 방지할 수 있습니다.
- **`safe_to_bootstrap` 플래그:** 정상 종료된 마지막 노드는 `grastate.dat` 의 `safe_to_bootstrap` 값이 `1` 로 설정됩니다. 비정상 종료된 노드는 `0` 이므로 수동으로 `1` 로 변경해야 부트스트랩이 가능합니다.

### 6-2. 복구 절차

**1단계: Primary 노드 판별**

3대 서버 모두에서 MariaDB 프로세스가 없는지 확인한 후 트랜잭션 번호를 추출합니다.

```bash
# 잔여 프로세스 확인
ps -ef | grep mysql

# 복구 위치(seqno) 추출
sudo /usr/sbin/mariadbd --wsrep-recover --datadir=/var/lib/mysql
```

로그 마지막의 `Recovered position: UUID:seqno` 값 중 **seqno가 가장 큰 노드**를 Primary로 선정합니다.
숫자가 같다면 `grastate.dat`의 `safe_to_bootstrap: 1`인 노드를 선택합니다.

**2단계: Primary 노드 부트스트랩**

```bash
# grastate.dat에서 safe_to_bootstrap: 1로 변경
sudo vi /var/lib/mysql/grastate.dat

# 클러스터 초기화 (Primary 노드에서만)
sudo galera_new_cluster

# 검증 (Size = 1)
sudo mariadb -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

**3단계: 나머지 노드 합류**

나머지 노드에서 하나씩 서비스를 시작합니다.

```bash
sudo systemctl start mariadb

# 최종 검증 (Size = 3)
sudo mariadb -u root -p -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

**4단계: 외부 애플리케이션 정상화**

DB 접속 실패로 `CrashLoopBackOff` 상태인 K8s 파드가 있다면 재시작합니다.

```bash
kubectl rollout restart deployment --all -n <네임스페이스>
```

### 6-3. 복구 체크리스트

| 완료 | 분류 | 점검 대상 및 명령어 | 기준 / 비고 |
| :---: | :--- | :--- | :--- |
| [ ] | **사전 조사** | `ps -ef \| grep mysql` | 3대 모두 잔여 프로세스 없음 |
| [ ] | **상태 추출** | `--wsrep-recover --datadir=<경로>` | 3대 중 `seqno` 최고값 판별 완료 |
| [ ] | **부트스트랩** | Primary: `sudo galera_new_cluster` | `wsrep_cluster_size` = 1 |
| [ ] | **노드 합류** | 나머지: `sudo systemctl start mariadb` | `wsrep_cluster_size` = 3 |
| [ ] | **앱 복구** | `kubectl rollout restart deployment` | 앱 파드 `Running` 확인 |

---

## 부록 A: 커스텀 데이터 경로 사용 시

OS 루트 디스크 용량이 작거나 별도 데이터 디스크(예: `/app`)에 보관해야 하는 경우의 절차입니다.

### A-1. 디렉토리 구성 및 초기화

```bash
# 디렉토리 생성 및 소유권 부여 (mysql 계정은 RPM 설치 시 자동 생성됨)
sudo mkdir -p /app/mariadb_data
sudo chown -R mysql:mysql /app/mariadb_data
sudo chmod 750 /app/mariadb_data

# DB 초기화 (커스텀 경로에는 시스템 테이블이 없으므로 필수)
sudo mysql_install_db --user=mysql --datadir=/app/mariadb_data
```

### A-2. Galera 설정에 datadir 명시

`/etc/my.cnf.d/01-galera.cnf` 의 `[mariadb]` 섹션 상단에 추가합니다.

```ini
datadir=/app/mariadb_data
```

### A-3. SELinux 컨텍스트 부여

기본 경로가 아니므로 `mysqld_db_t` 컨텍스트를 수동 부여해야 합니다.
SELinux 가 Permissive 모드여도, Enforcing 으로 전환할 가능성을 고려해 미리 설정해두는 것이 안전합니다.

```bash
sudo dnf install -y policycoreutils-python-utils    # semanage 가 없는 경우

sudo semanage fcontext -a -t mysqld_db_t "/app/mariadb_data(/.*)?"
sudo restorecon -R -v /app/mariadb_data

# 정책 확인
ls -Zd /app/mariadb_data
```

### A-4. systemd 보안 정책 (RHEL 9 계열에서만 필요)

Rocky 8 의 mariadb.service 는 기본적으로 사용자 정의 경로 쓰기를 허용하지만,
RHEL 9 계열로 마이그레이션하거나 systemd 정책이 강화된 환경에서는 아래 override 가 필요할 수 있습니다.

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

---

## 부록 B: HA(VIP) 구성 시 주의사항

Keepalived 등으로 VIP 를 구성할 때 주의할 점입니다.

- **Shared-Nothing 원칙 준수:** Galera Cluster 는 각 노드가 독립적인 스토리지를 가져야 합니다.
  동일한 SAN/iSCSI 디스크를 여러 노드에 동시 마운트하면 파일 시스템 메타데이터가 파손되어
  OS 가 디스크를 `Read-only`로 잠급니다.
- **해결책:** 반드시 노드별 로컬 디스크 또는 독립적인 볼륨을 사용하세요.
  클러스터 파일 시스템(GFS2 등)은 Galera 환경에서 권장되지 않습니다.
- **Failover 점검:** VIP 할당 직후 DB 가 멈춘다면, HA 솔루션이 노드를 격리(Fencing)하고 있지 않은지 확인하세요.
