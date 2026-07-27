# MariaDB Galera 10.11.18 업그레이드 트러블슈팅

## 1. 문서 목적

MariaDB Galera Cluster를 `10.11.14`에서 `10.11.18`로 롤링
업그레이드하면서 실제 발생한 문제와 해결 방법을 기록한다.

정상 업그레이드 순서와 최종 결과는
[업그레이드 가이드](galera-10.11.14-to-10.11.18-upgrade-guide.md)를
참조한다.

## 2. DNF exclude로 인한 설치 차단

### 2.1 증상

```text
All matches were filtered out by exclude filtering
```

MariaDB `10.11.14` 버전 고정을 위해 설정한 DNF `exclude` 또는
versionlock이 업그레이드 대상 패키지까지 차단한다.

### 2.2 확인

```bash
sudo dnf versionlock list
sudo grep -RniE '^[[:space:]]*exclude=' \
  /etc/dnf/dnf.conf \
  /etc/yum.repos.d
```

### 2.3 해결

정확한 패키지 버전을 지정하고 해당 설치 명령에서만 잠금을 우회한다.

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

`--disableexcludes=all`만 사용하고 패키지 버전을 생략하면 저장소의 더
최신 버전이 설치될 수 있으므로 반드시 전체 버전을 명시한다.

## 3. SELinux로 인한 SST 및 IST 실패

### 3.1 증상

```text
socat ... TCP-LISTEN:4444 ... Permission denied
Failed to open IST listener at tcp://1.1.1.156:4568
```

MariaDB 프로세스가 Galera SST 및 IST 포트에 바인딩하지 못해 Joiner가
클러스터에 합류하지 못한다.

### 3.2 포트 정책 확인

```bash
getenforce
sudo semanage port -l |
  grep -E 'mysqld_port_t|kerberos_port_t'
```

### 3.3 포트 정책 적용

모든 Galera 노드에서 필요한 포트를 `mysqld_port_t`로 등록한다.

```bash
sudo semanage port -a -t mysqld_port_t -p tcp 4444 ||
  sudo semanage port -m -t mysqld_port_t -p tcp 4444

sudo semanage port -a -t mysqld_port_t -p tcp 4567 ||
  sudo semanage port -m -t mysqld_port_t -p tcp 4567

sudo semanage port -a -t mysqld_port_t -p udp 4567 ||
  sudo semanage port -m -t mysqld_port_t -p udp 4567

sudo semanage port -a -t mysqld_port_t -p tcp 4568 ||
  sudo semanage port -m -t mysqld_port_t -p tcp 4568
```

Rocky Linux 9에서 `4444/TCP`가 이미 `kerberos_port_t`로 등록된 경우
추가가 아니라 수정이 필요하다. 같은 서버에서 Kerberos가 이 포트를
사용하는지 먼저 확인한다.

## 4. SST timeout 프로세스의 SELinux 거부

### 4.1 증상

Galera SST 스크립트가 실행한 `timeout` 프로세스의 `setpgid` 동작이
SELinux에 의해 거부된다.

### 4.2 거부 내역 확인

```bash
sudo ausearch -m AVC -c timeout
```

### 4.3 최소 권한 정책 적용

생성된 정책에 다음 권한만 포함되는지 검토한 후 적용한다.

```text
allow mysqld_t self:process setpgid;
```

```bash
cd /tmp
sudo ausearch -m AVC -c timeout --raw |
  sudo audit2allow -M galera_sst_timeout
sudo cat /tmp/galera_sst_timeout.te
sudo semodule -i /tmp/galera_sst_timeout.pp
```

`audit2allow` 출력 전체를 검토하지 않고 바로 적용하지 않는다.

## 5. 실패한 SST 프로세스가 종료되지 않음

### 5.1 증상

```text
ActiveState=deactivating
SubState=stop-sigterm
```

실패한 SST 관련 프로세스가 남아 MariaDB 서비스가 종료 대기 상태에서
빠져나오지 못한다.

### 5.2 사전 안전 확인

강제 종료 전에 다른 두 노드가 정상 Primary Component인지 확인한다.

```bash
sudo mariadb -NBe "
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'wsrep_cluster_size',
  'wsrep_cluster_status',
  'wsrep_local_state_comment'
);
"
```

다른 노드가 `Primary`, `Synced` 상태가 아니면 강제 종료하지 않는다.

### 5.3 장애 노드 서비스만 종료

장애 노드가 Joiner임을 확인한 후 해당 노드의 MariaDB 서비스
cgroup만 종료한다.

```bash
sudo systemctl kill \
  --kill-who=all \
  --signal=SIGKILL \
  mariadb

sudo systemctl reset-failed mariadb
```

SST 완료까지 명령이 대기하지 않도록 비동기로 다시 시작한다.

```bash
sudo systemctl start --no-block mariadb
sudo journalctl -u mariadb -f
```

## 6. mariadb-upgrade Phase 3 잠금 대기

### 6.1 증상

`mariadb-upgrade`가 다음 단계에서 장시간 진행되지 않는다.

```text
Phase 3/8: Running 'mysql_fix_privilege_tables'
```

프로세스 목록에서는 다음과 같은 잠금 대기가 확인됐다.

```text
ALTER TABLE proc ... Waiting for table metadata lock
DROP FUNCTION ... Waiting for table level lock
```

### 6.2 상태 확인

다른 터미널에서 업그레이드 프로세스와 DB 세션을 확인한다.

```bash
ps -ef |
  grep -E '[m]ariadb-upgrade|[m]ysql_upgrade'

sudo mariadb -e "SHOW FULL PROCESSLIST;"
```

출력이 잠시 멈춘 것만으로 프로세스를 종료하지 않는다. 동일한 잠금
대기가 계속되는지 확인한 후 조치한다.

### 6.3 해결

중단된 이전 업그레이드 세션이 남아 있으면 정확한 세션 ID를 다시
확인해 정리한다. 이미 종료된 ID를 `KILL`하면 다음 오류가 발생하지만
추가 장애는 아니다.

```text
ERROR 1094 (HY000): Unknown thread id
```

세션이 정리된 후 시스템 테이블을 먼저 처리하고 전체 업그레이드를
다시 실행한다.

```bash
sudo mariadb-upgrade \
  --force \
  --skip-write-binlog \
  --upgrade-system-tables

sudo mariadb-upgrade \
  --force \
  --skip-write-binlog
```

완료 여부를 확인한다.

```bash
sudo cat /var/lib/mysql/mysql_upgrade_info
```

기대값은 다음과 같다.

```text
10.11.18-MariaDB
```

## 7. root 전용 백업 경로의 와일드카드 문제

### 7.1 증상

```bash
sudo gzip -t /backup/pre-upgrade-10.11.14/*.sql.gz
```

```text
gzip: /backup/pre-upgrade-10.11.14/*.sql.gz: No such file or directory
```

파일이 실제로 존재하더라도 현재 사용자가 root 전용 디렉터리를 읽지
못하면 셸이 `sudo` 실행 전에 `*.sql.gz`를 확장하지 못한다.

`chmod 600 /path/*`도 같은 이유로 실패할 수 있다.

### 7.2 해결

root 셸 안에서 와일드카드를 확장한다.

```bash
sudo bash -c '
set -Eeuo pipefail
cd /backup/pre-upgrade-10.11.14
sha256sum -- *.sql.gz > SHA256SUMS
sha256sum -c SHA256SUMS
gzip -t -- *.sql.gz
chmod 600 -- *.sql.gz SHA256SUMS
'
```

또는 `find -exec`를 사용한다.

```bash
sudo find /backup/pre-upgrade-10.11.14 \
  -maxdepth 1 \
  -type f \
  -name '*.sql.gz' \
  -exec gzip -t {} \;
```

`sha256sum -c`에는 해시 문자열이 아니라 체크섬 목록 파일을 전달한다.

```bash
sudo sha256sum \
  -c /backup/pre-upgrade-10.11.14/SHA256SUMS
```

## 8. 백업 계정 인증 실패

### 8.1 증상

```text
ERROR 1045 (28000): Access denied for user 'backup_user'@'localhost'
```

DB 계정은 존재하지만 `/etc/mariadb-backup.cnf`의 비밀번호와 실제 계정
비밀번호가 일치하지 않았다.

### 8.2 확인

```bash
sudo mariadb -NBe "
SELECT User, Host
FROM mysql.global_priv
WHERE User='backup_user';
"

sudo mariadb -e \
  "SHOW GRANTS FOR 'backup_user'@'localhost';"
```

DB 계정 비밀번호와 인증 파일을 일치시킨 후 실제 인증 파일을 사용해
검증한다.

```bash
sudo mariadb \
  --defaults-extra-file=/etc/mariadb-backup.cnf \
  -NBe "SELECT CURRENT_USER(), VERSION();"
```

## 9. oneshot 백업 서비스가 inactive로 표시됨

### 9.1 증상

백업 실행 후 서비스가 다음처럼 표시된다.

```text
Active: inactive (dead)
```

### 9.2 판정

`Type=oneshot` 서비스는 작업을 완료하면 비활성 상태가 되는 것이
정상이다. 다음 값으로 성공 여부를 판단한다.

```text
code=exited, status=0/SUCCESS
```

```bash
sudo systemctl status mariadb-backup-dump.service --no-pager
sudo journalctl \
  -u mariadb-backup-dump.service \
  -n 50 \
  --no-pager
```

백업 후 Galera 상태도 확인한다.

```bash
sudo mariadb -NBe "
SHOW GLOBAL VARIABLES LIKE 'wsrep_desync';
SHOW GLOBAL STATUS LIKE 'wsrep_local_state_comment';
"
```

정상 기대값은 `wsrep_desync=OFF`, `Synced`이다.

## 10. 재발 방지 요약

- 패키지는 Release와 Architecture를 포함한 정확한 버전으로 설치한다.
- SELinux를 비활성화하지 않고 필요한 포트와 최소 권한만 허용한다.
- SST 또는 IST 실패 시 다른 노드의 Primary 상태를 먼저 확인한다.
- 한 노드가 완전히 `Synced`되기 전에는 다음 노드를 업그레이드하지 않는다.
- `mariadb-upgrade`가 멈추면 먼저 프로세스 목록과 잠금 상태를 확인한다.
- root 전용 경로의 와일드카드는 root 셸 또는 `find -exec` 안에서 처리한다.
- 업그레이드 후 패키지, 클러스터, DB 시스템 테이블, 백업을 모두 검증한다.
