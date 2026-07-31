# MariaDB 10.11.18 Galera 클러스터 가이드

## 1. 개요

Ubuntu 24.04 노드 3대 이상으로 MariaDB 10.11.18 Galera 클러스터를
구성하는 절차입니다.

모든 노드에 `scripts/install.sh` 또는 `scripts/install_online.sh`로
MariaDB 설치를 먼저 완료해야 합니다.

## 2. 예제 토폴로지

| 노드 | 노드명 | 내부 IP |
|---|---|---|
| Node 1 | `db1` | `10.10.10.11` |
| Node 2 | `db2` | `10.10.10.12` |
| Node 3 | `db3` | `10.10.10.13` |

Galera 통신에는 Floating IP나 NAT 주소가 아닌 노드 간 직접 통신
가능한 내부 IP를 사용하십시오.

## 3. 네트워크 요구 사항

노드 사이에 다음 포트가 허용되어야 합니다.

| 포트 | 프로토콜 | 용도 |
|---|---|---|
| 3306 | TCP | MariaDB 클라이언트 |
| 4444 | TCP | SST |
| 4567 | TCP/UDP | Galera 복제 |
| 4568 | TCP | IST |

OpenStack 보안 그룹, 네트워크 ACL, 호스트 UFW를 모두 확인하십시오.

## 4. 노드별 설정

각 노드의 컴포넌트 루트에서 실행합니다.

### 4.1. Node 1

```bash
sudo ./scripts/configure_galera.sh --configure \
  --node-name db1 \
  --node-address 10.10.10.11 \
  --cluster-nodes 10.10.10.11,10.10.10.12,10.10.10.13 \
  --cluster-name mariadb-prod
```

### 4.2. Node 2

```bash
sudo ./scripts/configure_galera.sh --configure \
  --node-name db2 \
  --node-address 10.10.10.12 \
  --cluster-nodes 10.10.10.11,10.10.10.12,10.10.10.13 \
  --cluster-name mariadb-prod
```

### 4.3. Node 3

```bash
sudo ./scripts/configure_galera.sh --configure \
  --node-name db3 \
  --node-address 10.10.10.13 \
  --cluster-nodes 10.10.10.11,10.10.10.12,10.10.10.13 \
  --cluster-name mariadb-prod
```

`--configure`는 설정만 기록하고 MariaDB를 재시작하지 않습니다.

## 5. 신규 클러스터 시작

### 5.1. 모든 노드 정지

세 노드의 MariaDB를 모두 정지합니다.

```bash
sudo systemctl stop mariadb
```

### 5.2. Node 1만 부트스트랩

신규 클러스터의 첫 번째 노드 한 대에서만 실행합니다.

```bash
sudo ./scripts/configure_galera.sh \
  --bootstrap-new-cluster \
  --new-cluster \
  --yes
```

정상 결과는 클러스터 크기 `1`, 상태 `Primary`, 로컬 상태 `Synced`
입니다.

### 5.3. Node 2 조인

```bash
sudo ./scripts/configure_galera.sh --join --yes
```

### 5.4. Node 3 조인

```bash
sudo ./scripts/configure_galera.sh --join --yes
```

## 6. 상태 확인

각 노드에서 실행합니다.

```bash
sudo ./scripts/configure_galera.sh --status
```

3노드 정상 상태는 다음과 같습니다.

```text
wsrep_cluster_size=3
wsrep_cluster_status=Primary
wsrep_local_state_comment=Synced
wsrep_connected=ON
wsrep_ready=ON
```

SQL로 직접 확인할 수도 있습니다.

```bash
sudo mariadb -e "
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'wsrep_cluster_size',
  'wsrep_cluster_status',
  'wsrep_local_state_comment',
  'wsrep_connected',
  'wsrep_ready'
);"
```

## 7. 복제 검증

Node 1에서 검증용 데이터베이스와 행을 생성합니다.

```bash
sudo mariadb -e "
CREATE DATABASE galera_validation;
CREATE TABLE galera_validation.replication_test (
  id INT PRIMARY KEY,
  source_node VARCHAR(64) NOT NULL
);
INSERT INTO galera_validation.replication_test
VALUES (1, 'db1');"
```

Node 2와 Node 3에서 조회합니다.

```bash
sudo mariadb -e "
SELECT * FROM galera_validation.replication_test;"
```

검증이 끝나면 한 노드에서 삭제합니다.

```bash
sudo mariadb -e "DROP DATABASE galera_validation;"
```

## 8. 순차 재시작

운영 중에는 한 번에 한 노드만 재시작합니다.

```bash
sudo systemctl restart mariadb
sudo ./scripts/configure_galera.sh --status
```

해당 노드가 `Synced`로 복귀한 것을 확인한 뒤 다음 노드를
재시작하십시오.

## 9. 전체 장애 복구

전체 노드가 중지된 경우 임의 노드에서 신규 부트스트랩을 실행하면
데이터 유실 또는 클러스터 분리가 발생할 수 있습니다.

### 9.1. 모든 노드의 상태 확인

각 노드에서 다음 파일을 확인합니다.

```bash
sudo cat /var/lib/mysql/grastate.dat
```

`seqno`가 가장 높은 노드를 우선 후보로 선택합니다.

### 9.2. 필요 시 복구 위치 확인

`seqno=-1`이면 MariaDB를 정지한 상태에서 복구 명령을 실행합니다.

```bash
sudo galera_recovery
```

모든 노드의 복구 위치를 비교해 가장 최신 노드를 선택합니다.

### 9.3. 안전한 노드 지정

선택한 노드의 `grastate.dat`에서 다음 값을 설정합니다.

```text
safe_to_bootstrap: 1
```

다른 노드는 `safe_to_bootstrap: 0` 상태를 유지해야 합니다.

### 9.4. 복구 부트스트랩

최신 노드 한 대에서만 실행합니다.

```bash
sudo galera_new_cluster
```

상태를 확인한 뒤 나머지 노드를 한 대씩 시작합니다.

```bash
sudo systemctl start mariadb
```

## 10. Manual Galera Configuration

자동 구성 스크립트를 사용할 수 없는 경우 각 노드의
`/etc/mysql/mariadb.conf.d/60-galera.cnf`를 직접 작성합니다.

```ini
[mariadb]
wsrep_on=ON
wsrep_provider=/usr/lib/libgalera_smm.so
wsrep_cluster_name=mariadb-prod
wsrep_cluster_address=gcomm://10.10.10.11,10.10.10.12,10.10.10.13
wsrep_node_name=db1
wsrep_node_address=10.10.10.11
wsrep_sst_method=rsync
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
```

실제 provider 경로는 다음 명령으로 확인하십시오.

```bash
dpkg-query -L galera-4 | grep '/libgalera_smm.so$'
```

첫 번째 노드는 다음 명령으로 시작합니다.

```bash
sudo galera_new_cluster
```

나머지 노드는 일반 서비스 시작으로 조인합니다.

```bash
sudo systemctl start mariadb
```

## 11. 문제 해결

MariaDB 로그를 확인합니다.

```bash
sudo journalctl -u mariadb -n 200 --no-pager
```

포트 수신 상태를 확인합니다.

```bash
sudo ss -lntup |
  grep -E ':(3306|4444|4567|4568)\b'
```

UFW 상태를 확인합니다.

```bash
sudo ufw status verbose
```

OpenStack 환경에서는 호스트 방화벽뿐 아니라 보안 그룹의 내부 IP
인바운드와 아웃바운드 규칙도 함께 확인하십시오.
