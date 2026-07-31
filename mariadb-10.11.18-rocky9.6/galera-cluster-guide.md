# MariaDB 10.11.18 Galera 3노드 구성 가이드

Galera 구성 스크립트는 각 노드의 설정, 신규 클러스터 부트스트랩,
클러스터 조인 및 상태 확인을 지원합니다. 잘못된 노드에서 부트스트랩하면
데이터가 분기되거나 유실될 수 있으므로 3대 전체를 원격으로 자동
제어하지는 않습니다.

## 온라인 설치

세 노드에서 각각 MariaDB와 Galera 패키지를 설치합니다.

```bash
sudo ./scripts/install_online.sh --install
```

오프라인 환경이라면 RPM을 반입한 뒤 다음 명령을 실행합니다.

```bash
sudo ./scripts/install.sh --install
```

## 전제 조건

- 세 노드 모두 MariaDB 10.11.18과 Galera 4 26.4.27이 설치되어야 합니다.
- 세 노드의 시간이 동기화되어야 합니다.
- 노드 간 이름 해석과 양방향 통신이 가능해야 합니다.
- 노드별 데이터 디렉터리는 독립된 로컬 디스크를 사용해야 합니다.
- 기존 데이터가 있는 클러스터에는 신규 구성 절차를 적용하지 마십시오.

예시 주소는 다음과 같습니다.

| 노드 | 호스트명 | IP 주소 |
| --- | --- | --- |
| 1 | `db1` | `10.10.10.11` |
| 2 | `db2` | `10.10.10.12` |
| 3 | `db3` | `10.10.10.13` |

## 네트워크 포트

세 노드 사이에 다음 포트를 허용합니다.

| 포트 | 프로토콜 | 용도 |
| --- | --- | --- |
| 3306 | TCP | SQL 및 상태 전송 |
| 4444 | TCP | SST |
| 4567 | TCP/UDP | Galera 복제 |
| 4568 | TCP | IST |

firewalld를 사용하는 경우 각 노드에서 실행합니다.

```bash
sudo firewall-cmd --permanent --add-port=3306/tcp
sudo firewall-cmd --permanent --add-port=4444/tcp
sudo firewall-cmd --permanent --add-port=4567/tcp
sudo firewall-cmd --permanent --add-port=4567/udp
sudo firewall-cmd --permanent --add-port=4568/tcp
sudo firewall-cmd --reload
```

SELinux를 비활성화하지 말고 필요한 포트를 MariaDB 타입으로
등록합니다.

```bash
sudo semanage port -a -t mysqld_port_t -p tcp 4444 2>/dev/null || \
  sudo semanage port -m -t mysqld_port_t -p tcp 4444
sudo semanage port -a -t mysqld_port_t -p tcp 4567 2>/dev/null || \
  sudo semanage port -m -t mysqld_port_t -p tcp 4567
sudo semanage port -a -t mysqld_port_t -p udp 4567 2>/dev/null || \
  sudo semanage port -m -t mysqld_port_t -p udp 4567
sudo semanage port -a -t mysqld_port_t -p tcp 4568 2>/dev/null || \
  sudo semanage port -m -t mysqld_port_t -p tcp 4568
```

## Galera 설정

### 구성 스크립트 사용

각 노드에서 자신의 노드명과 주소를 지정합니다. `CLUSTER_NODES`의
순서는 세 노드에서 동일하게 유지합니다.

`db1`에서 실행합니다.

```bash
sudo ./scripts/configure_galera.sh --configure \
  --node-name db1 \
  --node-address 10.10.10.11 \
  --cluster-nodes 10.10.10.11,10.10.10.12,10.10.10.13
```

`db2`에서 실행합니다.

```bash
sudo ./scripts/configure_galera.sh --configure \
  --node-name db2 \
  --node-address 10.10.10.12 \
  --cluster-nodes 10.10.10.11,10.10.10.12,10.10.10.13
```

`db3`에서 실행합니다.

```bash
sudo ./scripts/configure_galera.sh --configure \
  --node-name db3 \
  --node-address 10.10.10.13 \
  --cluster-nodes 10.10.10.11,10.10.10.12,10.10.10.13
```

이 작업은 `/etc/my.cnf.d/60-galera.cnf`를 생성하고 방화벽 및 SELinux
포트를 설정하지만 MariaDB를 재시작하지 않습니다.

### 수동 설정
각 노드에서 `/etc/my.cnf.d/60-galera.cnf`를 생성합니다.
`wsrep_node_name`과 `wsrep_node_address`만 노드별 값으로 변경합니다.

```ini
[mariadb]
bind-address=0.0.0.0
binlog-format=ROW
default-storage-engine=InnoDB
innodb-autoinc-lock-mode=2

wsrep-on=ON
wsrep-provider=/usr/lib64/galera-4/libgalera_smm.so
wsrep-cluster-name=mariadb-prod
wsrep-cluster-address=gcomm://10.10.10.11,10.10.10.12,10.10.10.13

wsrep-node-name=db1
wsrep-node-address=10.10.10.11

wsrep-sst-method=rsync
```

설정 문법과 공급자 경로를 확인합니다.

```bash
test -f /usr/lib64/galera-4/libgalera_smm.so
sudo mariadbd --verbose --help >/dev/null
```

## 신규 클러스터 기동

세 노드의 MariaDB를 모두 중지합니다.

```bash
sudo systemctl stop mariadb
```

데이터의 기준이 될 `db1`에서만 클러스터를 부트스트랩합니다.

```bash
sudo ./scripts/configure_galera.sh \
  --bootstrap-new-cluster \
  --new-cluster \
  --yes
```

결과가 `1`인지 확인한 후 `db2`를 시작합니다.

```bash
sudo ./scripts/configure_galera.sh --join
```

클러스터 크기가 `2`가 되고 `db2` 상태가 `Synced`인지 확인한 뒤
`db3`를 시작합니다.

```bash
sudo ./scripts/configure_galera.sh --join
```

세 노드에서 최종 상태를 확인합니다.

```bash
sudo ./scripts/configure_galera.sh --status
```

정상 기대값은 다음과 같습니다.

- `wsrep_cluster_size`: `3`
- `wsrep_cluster_status`: `Primary`
- `wsrep_connected`: `ON`
- `wsrep_ready`: `ON`
- `wsrep_local_state_comment`: `Synced`

## 복제 검증

`db1`에서 테스트 데이터를 생성합니다.

```bash
sudo mariadb -e "
CREATE DATABASE IF NOT EXISTS galera_test;
CREATE TABLE IF NOT EXISTS galera_test.health (
  id INT PRIMARY KEY,
  node_name VARCHAR(64),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
INSERT INTO galera_test.health (id, node_name)
VALUES (1, 'db1')
ON DUPLICATE KEY UPDATE node_name=VALUES(node_name);
"
```

`db2`와 `db3`에서 데이터가 보이는지 확인합니다.

```bash
sudo mariadb -e "SELECT * FROM galera_test.health;"
```

## 전체 장애 복구

모든 노드가 동시에 중지된 경우 임의 노드에서
`galera_new_cluster`를 실행하지 마십시오.

1. 모든 노드의 MariaDB가 중지되었는지 확인합니다.
1. 각 노드의 `/var/lib/mysql/grastate.dat`에서 `seqno`와
   `safe_to_bootstrap` 값을 확인합니다.
1. 정상 종료가 아니면 각 노드에서 `galera_recovery`를 실행하여
   복구 위치를 확인합니다.
1. 가장 높은 복구 위치를 가진 노드를 하나만 선정합니다.
1. 선정한 노드의 `safe_to_bootstrap`만 `1`로 설정합니다.
1. 선정한 노드에서만 `galera_new_cluster`를 실행합니다.
1. 상태가 `Primary`, `Synced`인지 확인한 뒤 나머지 노드를 한 대씩
   시작합니다.

복구 위치가 서로 다르거나 데이터 정합성을 판단할 수 없다면 자동
복구를 중단하고 최신 검증 백업을 기준으로 복원하십시오.

## 운영 주의사항

- 클러스터 재기동과 전체 장애 복구는 서로 다른 절차입니다.
- 일반 재기동 시에는 `systemctl start mariadb`를 사용합니다.
- `galera_new_cluster`는 신규 구성 또는 검증된 전체 장애 복구에서
  선택된 단 한 노드에서만 실행합니다.
- 두 노드 클러스터는 한 노드 장애 시 쿼럼을 잃으므로 3노드를
  유지합니다.
- 업그레이드는 전체 백업 후 한 노드씩 수행하고 매번 `Synced` 복귀를
  확인합니다.
