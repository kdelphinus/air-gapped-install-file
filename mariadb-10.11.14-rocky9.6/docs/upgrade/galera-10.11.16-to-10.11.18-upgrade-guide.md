# MariaDB Galera 10.11.16에서 10.11.18 업그레이드 가이드

## 1. 문서 목적

Rocky Linux 9 기반 3노드 MariaDB Galera Cluster를 MariaDB
`10.11.16`에서 `10.11.18`로 롤링 업그레이드한 결과와 재수행 절차를
기록한다.

이 문서는 실제 테스트에서 확인한 명령, 장애 원인, 복구 방법 및 최종
검증 결과를 기준으로 작성했다. 상세 장애 대응은
[트러블슈팅 문서](galera-10.11.16-to-10.11.18-troubleshooting.md)를
참조한다.

## 2. 완료 범위

- MariaDB `10.11.16`에서 `10.11.18`로 3노드 롤링 업그레이드
- Galera `26.4.25`에서 `26.4.27`로 업그레이드
- 업그레이드 순서 `DB3 -> DB2 -> DB1` 준수
- 각 노드의 `mariadb-upgrade` 완료
- 최종 3노드 `Primary`, `Synced`, `Ready` 상태 확인
- DB1 Simple Backup의 업그레이드 전후 정상 동작 확인
- 업그레이드 전 Dump 별도 보존 및 SHA256, gzip 무결성 확인

다음 항목은 이 업그레이드 완료 범위와 별개다.

- 별도 인스턴스를 이용한 전체 복원 리허설
- 업무 애플리케이션별 기능 및 성능 시험
- MariaDB, Galera, SST/IST의 TLS 및 Cipher 정책 변경

## 3. 테스트 환경

| 노드 | 호스트 이름 | Galera Fixed IP | 관리용 Floating IP |
| --- | --- | --- | --- |
| DB1 | `db-upgrade-test-1` | `1.1.1.233` | `10.10.10.101` |
| DB2 | `db-upgrade-test-2` | `1.1.1.73` | `10.10.10.103` |
| DB3 | `db-upgrade-test-3` | `1.1.1.156` | `10.10.10.105` |

- Galera 복제에는 OpenStack Fixed IP만 사용했다.
- Floating IP는 SSH와 관리 접속에만 사용했다.
- `wsrep_cluster_address`는 다음과 같이 구성했다.

```ini
wsrep_cluster_address="gcomm://1.1.1.233,1.1.1.73,1.1.1.156"
```

## 4. 버전 및 작업 정책

| 항목 | 업그레이드 전 | 업그레이드 후 |
| --- | --- | --- |
| MariaDB | `10.11.16-1.el9` | `10.11.18-1.el9` |
| Galera | `26.4.25-1.el9` | `26.4.27-1.el9` |
| 운영체제 | Rocky Linux 9 | 변경 없음 |

- MariaDB 공식 온라인 DNF 저장소를 사용했다.
- 저장소에 여러 `10.11.x` 버전이 함께 노출되므로 패키지 버전을 정확히
  지정했다.
- 모든 노드를 동시에 중지하지 않고 `DB3 -> DB2 -> DB1` 순서로 한
  노드씩 작업했다.
- 작업 중 항상 나머지 노드가 `Primary` 상태를 유지하는지 확인했다.

## 5. 업그레이드 전 백업

### 5.1 Simple Backup 구성

논리 백업은 DB1에서만 수행했다.

| 항목 | 경로 |
| --- | --- |
| 백업 스크립트 | `/opt/mariadb-backup/backup-dump.sh` |
| 인증 파일 | `/etc/mariadb-backup.cnf` |
| 일일 Dump | `/backup/dump` |
| 업그레이드 전 보존본 | `/backup/pre-upgrade-10.11.16` |

백업 계정은 `backup_user@localhost`이며 다음 최소 권한을 사용했다.

```sql
GRANT SELECT, SHOW VIEW, EVENT, TRIGGER
ON *.* TO 'backup_user'@'localhost';
```

인증 파일의 계정과 비밀번호가 실제 DB 계정과 일치하는지 확인했다.

```bash
sudo mariadb \
  --defaults-extra-file=/etc/mariadb-backup.cnf \
  -NBe "SELECT CURRENT_USER(), VERSION();"
```

백업 구성과 운영 절차는
[Galera Simple Backup 가이드](../backup-restore/galera-backup-simple-guide.md)를
참조한다.

### 5.2 업그레이드 전 Dump 보존

일일 보존 주기의 정리 대상에서 제외하기 위해 최신 Dump를 별도
디렉터리에 복사했다.

```bash
sudo install -d \
  -o root \
  -g root \
  -m 700 \
  /backup/pre-upgrade-10.11.16

sudo bash -c '
set -Eeuo pipefail

latest_dump=$(find /backup/dump \
  -maxdepth 1 \
  -type f \
  -name "mariadb_full_*.sql.gz" \
  -printf "%T@ %p\n" |
  sort -nr |
  head -1 |
  cut -d" " -f2-)

test -n "${latest_dump}"
cp -a -- "${latest_dump}" /backup/pre-upgrade-10.11.16/
'
```

### 5.3 무결성 검증

보존 디렉터리는 root 전용이므로 root 셸 안에서 와일드카드를 확장했다.

```bash
sudo bash -c '
set -Eeuo pipefail
cd /backup/pre-upgrade-10.11.16
sha256sum -- *.sql.gz > SHA256SUMS
sha256sum -c SHA256SUMS
gzip -t -- *.sql.gz
chmod 600 -- *.sql.gz SHA256SUMS
'
```

테스트 결과 SHA256 검사는 `OK`, gzip 검사는 종료 코드 `0`이었다.

## 6. 업그레이드 전 점검

각 노드에서 현재 패키지와 클러스터 상태를 기록했다.

```bash
rpm -qa --qf \
  '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' |
  grep -Ei '^(MariaDB|galera-4)' |
  sort

sudo mariadb -NBe "
SELECT @@hostname, VERSION();
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'wsrep_cluster_size',
  'wsrep_cluster_status',
  'wsrep_local_state_comment',
  'wsrep_ready',
  'wsrep_connected'
);
SHOW GLOBAL VARIABLES LIKE 'wsrep_desync';
"
```

작업 시작 기준은 다음과 같다.

- `wsrep_cluster_size = 3`
- `wsrep_cluster_status = Primary`
- 모든 노드의 `wsrep_local_state_comment = Synced`
- `wsrep_ready = ON`
- `wsrep_connected = ON`
- `wsrep_desync = OFF`

## 7. 노드별 롤링 업그레이드 절차

다음 절차를 DB3, DB2, DB1 순서로 한 노드씩 수행했다. 현재 작업 중인
노드가 정상화되기 전에는 다음 노드로 진행하지 않는다.

자동화 스크립트를 사용할 때도 한 번에 한 노드만 실행한다. 인자 없이
실행하면 사용법만 표시되며, 실제 업그레이드에는 `--yes`
옵션이 필요하다.

```bash
# 모든 노드에서 사전 상태 확인
sudo ./scripts/upgrade_galera_10.11.18.sh --check-only

# DB3
sudo ./scripts/upgrade_galera_10.11.18.sh \
  --upgrade-node \
  --yes

# DB3가 완전히 Synced된 것을 확인한 후 DB2
sudo ./scripts/upgrade_galera_10.11.18.sh \
  --upgrade-node \
  --yes

# DB2가 완전히 Synced된 것을 확인한 후 DB1
# 현재 환경의 DB1이 백업 노드이므로 --backup-node를 함께 지정한다.
sudo ./scripts/upgrade_galera_10.11.18.sh \
  --all \
  --backup-node \
  --yes

# 전체 업그레이드 완료 후 백업 노드 검증
sudo ./scripts/upgrade_galera_10.11.18.sh \
  --verify-backup \
  --backup-node
```

### 7.1 MariaDB 중지

```bash
sudo systemctl stop mariadb
sudo systemctl status mariadb --no-pager
```

### 7.2 정확한 버전으로 패키지 업그레이드

기존 `exclude` 또는 `versionlock`은 이 명령에서만 우회했다.

```bash
sudo dnf \
  --disableexcludes=all \
  --disableplugin=versionlock \
  install -y \
  MariaDB-server-10.11.18-1.el9.x86_64 \
  MariaDB-client-10.11.18-1.el9.x86_64 \
  MariaDB-common-10.11.18-1.el9.x86_64 \
  MariaDB-shared-10.11.18-1.el9.x86_64 \
  MariaDB-backup-10.11.18-1.el9.x86_64 \
  galera-4-26.4.27-1.el9.x86_64
```

설치된 패키지를 확인했다.

```bash
rpm -qa --qf \
  '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' |
  grep -Ei '^(MariaDB|galera-4)' |
  sort
```

### 7.3 MariaDB 시작 및 동기화 확인

SST 또는 IST가 발생할 수 있으므로 비동기로 시작하고 로그를 확인했다.

```bash
sudo systemctl start --no-block mariadb
sudo journalctl -u mariadb -f
```

별도 터미널에서 서비스와 클러스터 상태를 확인했다.

```bash
sudo systemctl status mariadb --no-pager

sudo mariadb -NBe "
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'wsrep_cluster_size',
  'wsrep_cluster_status',
  'wsrep_local_state_comment',
  'wsrep_ready',
  'wsrep_connected'
);
"
```

해당 노드가 `Synced`, `Ready=ON`, `Connected=ON`이 된 후 다음 단계로
진행했다.

### 7.4 시스템 테이블 및 전체 업그레이드

테스트 중 Phase 3 메타데이터 잠금을 경험했으므로 DB1에서는 시스템
테이블을 먼저 처리한 후 전체 검사를 수행했다.

```bash
sudo mariadb-upgrade \
  --force \
  --skip-write-binlog \
  --upgrade-system-tables

sudo mariadb-upgrade \
  --force \
  --skip-write-binlog
```

완료 버전을 확인했다.

```bash
sudo cat /var/lib/mysql/mysql_upgrade_info
```

기대값은 다음과 같다.

```text
10.11.18-MariaDB
```

### 7.5 노드 완료 판정

```bash
sudo mariadb -NBe "
SELECT @@hostname, VERSION();
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'wsrep_cluster_size',
  'wsrep_cluster_status',
  'wsrep_local_state_comment',
  'wsrep_ready',
  'wsrep_connected'
);
SHOW GLOBAL VARIABLES LIKE 'wsrep_desync';
"
```

다음 조건을 모두 만족해야 해당 노드의 작업이 완료된 것이다.

- MariaDB 버전이 `10.11.18-MariaDB`
- `wsrep_cluster_size = 3`
- `wsrep_cluster_status = Primary`
- `wsrep_local_state_comment = Synced`
- `wsrep_ready = ON`
- `wsrep_connected = ON`
- `wsrep_desync = OFF`

## 8. 테스트 중 발생한 주요 문제

### 8.1 DNF 버전 고정 정책에 의한 설치 차단

`All matches were filtered out by exclude filtering` 오류가 발생했다.
정확한 패키지 버전을 지정하고 해당 설치 명령에서만 `exclude`와
`versionlock`을 우회해 해결했다.

### 8.2 SELinux에 의한 SST 및 IST 차단

SELinux가 `4444/TCP`, `4568/TCP` 리스닝과 SST 내부 `timeout` 프로세스의
`setpgid` 동작을 차단했다. Galera 포트를 `mysqld_port_t`로 등록하고
최소 권한 SELinux 정책 모듈을 적용해 해결했다.

Rocky Linux 9에서는 `4444/TCP`가 `kerberos_port_t`로 등록되어 있을 수
있으므로 Kerberos 사용 여부를 먼저 확인해야 한다.

### 8.3 실패한 SST 프로세스가 종료 대기 상태에 머묾

서비스가 `deactivating/stop-sigterm` 상태에서 멈췄다. 나머지 두 노드가
정상 `Primary`이고 장애 노드가 Joiner임을 확인한 후 해당 노드의
MariaDB 서비스 cgroup만 종료하고 재시작했다.

### 8.4 mariadb-upgrade Phase 3 잠금 대기

DB2에서 `mysql.proc` 변경 작업이 메타데이터 잠금을 기다리며 멈췄다.
남아 있는 업그레이드 세션을 정리한 후 시스템 테이블 전용 업그레이드와
전체 업그레이드를 순서대로 실행해 완료했다.

세부 진단 및 복구 명령은
[트러블슈팅 문서](galera-10.11.16-to-10.11.18-troubleshooting.md)를
참조한다.

### 8.5 mysql_upgrade_info에 이전 버전이 남음

패키지, 실행 중인 서버 및 Galera는 모두 `10.11.18`과 정상 상태였지만,
`/var/lib/mysql/mysql_upgrade_info`에 `10.11.16-MariaDB`가 남아 자동화
스크립트의 마지막 검증만 실패했다.

수정된 스크립트는 실행 중인 MariaDB가 이미 `10.11.18`이면 DNF 설치와
서비스 재시작을 생략한다. 이전 버전의 `mysql_upgrade_info`는 다음과 같은
이름으로 보존하고 `mariadb-upgrade --force`를 다시 실행해 완료 파일을
정상적으로 생성한다.

```text
/var/lib/mysql/mysql_upgrade_info.pre-YYYYmmdd_HHMMSS
```

따라서 동일한 노드에서 업그레이드 명령을 다시 실행한다.

```bash
sudo ./scripts/upgrade_galera_10.11.18.sh \
  --upgrade-node \
  --yes
```

재실행 완료 기준은 다음과 같다.

- DNF 설치 및 MariaDB 서비스 재시작 단계가 생략됨
- `mariadb-upgrade`의 Phase 8/8 완료
- `mysql_upgrade_info`가 `10.11.18-MariaDB`로 확인됨
- Galera가 `size=3`, `Primary`, `Synced`, `Ready=ON`으로 확인됨
## 9. 최종 검증 결과

### 9.1 패키지 및 클러스터

| 노드 | MariaDB | Galera | 클러스터 상태 |
| --- | --- | --- | --- |
| DB1 | `10.11.18-1.el9` | `26.4.27-1.el9` | `Primary`, `Synced` |
| DB2 | `10.11.18-1.el9` | `26.4.27-1.el9` | `Primary`, `Synced` |
| DB3 | `10.11.18-1.el9` | `26.4.27-1.el9` | `Primary`, `Synced` |

최종 확인 시 클러스터 크기는 `3`, 모든 노드는 `Ready=ON`,
`Connected=ON`, `wsrep_desync=OFF`였다.

### 9.2 DB1 백업

업그레이드 후 DB1에서 백업 서비스를 수동 실행했다.

```bash
sudo systemctl start mariadb-backup-dump.service
sudo systemctl status mariadb-backup-dump.service --no-pager
```

`Type=oneshot` 서비스이므로 작업 후 `inactive (dead)`로 표시되는 것은
정상이다. 성공 기준은 `code=exited, status=0/SUCCESS`이다.

생성된 백업은 다음과 같다.

```text
/backup/dump/mariadb_full_20260723_101137.sql.gz
```

확인된 SHA256은 다음과 같다.

```text
f7fe556695f1ea1f497873a592af9efe68b3f3846b4173545874e3366cd46e60
```

gzip 무결성 검사, `backup_user` 인증, `wsrep_desync=OFF`,
`wsrep_local_state_comment=Synced`를 확인했다.

백업 타이머도 다시 활성화했다.

```bash
sudo systemctl enable --now mariadb-backup-dump.timer
sudo systemctl list-timers mariadb-backup-dump.timer --all
```

서버 표시 기준 `17:00 UTC`는 다음 날 `02:00 Asia/Seoul`에 해당한다.

## 10. 최종 체크리스트

- [x] 3노드 Galera Cluster 사전 정상 상태 확인
- [x] DB1 업그레이드 전 논리 백업 생성
- [x] 업그레이드 전 Dump 별도 보존
- [x] SHA256 및 gzip 무결성 확인
- [x] DB3를 MariaDB 10.11.18로 업그레이드
- [x] DB3의 SST/IST 및 `Synced` 상태 확인
- [x] DB2를 MariaDB 10.11.18로 업그레이드
- [x] DB2의 시스템 테이블과 전체 `mariadb-upgrade` 완료
- [x] DB1을 MariaDB 10.11.18로 업그레이드
- [x] DB1의 시스템 테이블과 전체 `mariadb-upgrade` 완료
- [x] 전체 노드의 패키지 버전 확인
- [x] 클러스터 크기 `3`, `Primary`, 전체 `Synced` 확인
- [x] 업그레이드 후 DB1 논리 백업 성공
- [x] 백업 계정 인증 및 백업 타이머 확인
- [ ] 별도 인스턴스 전체 복원 리허설
- [ ] 업무 애플리케이션별 접속 및 기능 검증
- [ ] TLS/HMAC 점검 대상 포트와 Cipher 확인 및 별도 조치

## 11. 완료 판정

2026-07-23 기준 MariaDB Galera 3노드의 `10.11.16`에서 `10.11.18`로
롤링 업그레이드와 업그레이드 후 논리 백업 검증을 완료했다.

운영 반영 시에도 이 문서의 순서와 중단 조건을 적용하고, 한 노드가
완전히 `Synced` 상태로 복귀한 뒤 다음 노드를 작업한다.
