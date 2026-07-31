# MariaDB 10.11.18 설치 가이드

이 문서는 Rocky Linux 9 계열 x86_64 서버에 MariaDB 10.11.18을
오프라인 RPM으로 설치하는 절차를 설명합니다.

## 전제 조건

- 인터넷 연결 호스트와 폐쇄망 대상 서버의 OS 메이저 버전 및 아키텍처가 동일해야 합니다.
- 대상 서버에서 `root` 또는 `sudo` 권한이 필요합니다.
- 신규 설치 전 `/var/lib/mysql`에 기존 데이터가 없는지 확인합니다.
- 기존 DB 업그레이드 전에는 검증된 전체 백업을 준비합니다.

## 온라인 설치

인터넷 연결이 가능한 대상 서버에서는 RPM 수집과 설치를 한 번에
수행할 수 있습니다.

```bash
sudo ./scripts/install_online.sh --install
```

기존 MariaDB 10.11 계열을 업그레이드하려면 다음 명령을 사용합니다.

```bash
sudo ./scripts/install_online.sh --upgrade
```

사내 MariaDB 미러를 사용하는 경우 저장소 URL을 지정합니다.

```bash
sudo MARIADB_REPO_URL="https://repo.example.local/mariadb/10.11.18" \
  ./scripts/install_online.sh --install
```

온라인 설치도 RPM을 `db/rpms`와 `common/rpms`에 먼저 내려받고 버전을
검증한 후 동일한 `install.sh`를 실행합니다. 따라서 온라인·오프라인
설치의 설정과 검증 절차가 같습니다.

## 폐쇄망 설치 파일 준비

인터넷 연결이 가능한 Rocky Linux 9 x86_64 호스트에서 컴포넌트 루트로
이동하여 실행합니다.

```bash
sudo ./scripts/download_assets_offline.sh
```

사내 미러를 사용해야 한다면 저장소 URL을 지정할 수 있습니다.

```bash
sudo MARIADB_REPO_URL="https://repo.example.local/mariadb/10.11.18" \
  ./scripts/download_assets_offline.sh
```

다운로드 후 다음 디렉터리에 RPM 파일이 생성되었는지 확인합니다.

```bash
find db/rpms common/rpms -maxdepth 1 -type f -name '*.rpm' -print
```

컴포넌트 폴더 전체를 폐쇄망 서버로 반입합니다.

## 설치 설정

설치 전에 `install.conf`를 검토합니다.

```bash
vi install.conf
```

주요 값은 다음과 같습니다.

| 설정 | 기본값 | 설명 |
| --- | --- | --- |
| `BIND_ADDRESS` | `0.0.0.0` | MariaDB 수신 주소 |
| `PORT` | `3306` | MariaDB TCP 포트 |
| `MAX_CONNECTIONS` | `1000` | 최대 동시 연결 수 |
| `LOWER_CASE_TABLE_NAMES` | `1` | 테이블명 대소문자 처리 |
| `SECURE_FILE_PRIV` | `/var/lib/mysql-files` | 서버 파일 입출력 허용 경로 |
| `LOCAL_INFILE` | `OFF` | 클라이언트 로컬 파일 적재 허용 여부 |
| `OPEN_FIREWALL` | `false` | firewalld 포트 자동 개방 여부 |

`LOWER_CASE_TABLE_NAMES`는 데이터 디렉터리를 초기화한 뒤 변경하지
마십시오.

## 자동 설치

컴포넌트 루트에서 실행합니다.

```bash
sudo ./scripts/install.sh --install
```

비대화형 실행이 필요하면 명시적으로 승인 옵션을 추가합니다.

```bash
sudo ./scripts/install.sh --install --yes
```

스크립트는 다음 작업을 수행합니다.

1. Rocky Linux/RHEL 9 및 x86_64 여부를 검사합니다.
1. RPM 번들에 MariaDB 10.11.18과 Galera 26.4.27이 있는지 검사합니다.
1. OS 기본 MariaDB 모듈을 비활성화합니다.
1. 로컬 RPM만 사용하여 패키지를 설치합니다.
1. `install.conf`를 `/etc/my.cnf.d/90-airgap-mariadb.cnf`에 반영합니다.
1. 서비스를 시작하고 `mariadb-upgrade`를 수행합니다.
1. 실행 버전과 서비스 상태를 검증합니다.

## 기존 설치 처리

옵션 없이 실행하면 기존 설치 상태에 따라 메뉴가 표시됩니다.

```bash
sudo ./scripts/install.sh
```

10.11 계열에서 업그레이드하려면 다음 명령을 사용합니다.

```bash
sudo ./scripts/install.sh --upgrade
```

10.11.18 패키지를 다시 설치하되 데이터를 유지하려면 다음 명령을
사용합니다.

```bash
sudo ./scripts/install.sh --reinstall
```

업그레이드 전에 반드시 논리 백업 또는 물리 백업을 별도 저장소에
보관하고 복구 테스트를 완료하십시오.

## 설치 확인

```bash
sudo ./scripts/install.sh --status
sudo mariadb -e "SELECT VERSION();"
sudo mariadb -e "SHOW VARIABLES LIKE 'secure_file_priv';"
sudo mariadb -e "SHOW VARIABLES LIKE 'local_infile';"
```

원격 접속을 허용한 경우 대상 서버 외부에서 TCP 연결도 확인합니다.

```bash
mariadb -h DB_SERVER_IP -P 3306 -u APP_USER -p
```

## 초기 보안 설정

MariaDB 10.11의 로컬 root 계정은 기본적으로 Unix 소켓 인증을 사용할
수 있습니다. 운영 정책에 맞추어 다음 대화형 명령을 수행합니다.

```bash
sudo mariadb-secure-installation
```

애플리케이션 DB와 계정은 비밀번호가 셸 기록에 남지 않도록 MariaDB
콘솔에서 생성합니다.

```bash
sudo mariadb
```

```sql
CREATE DATABASE appdb
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
CREATE USER 'appuser'@'10.%' IDENTIFIED BY 'CHANGE_ME';
GRANT ALL PRIVILEGES ON appdb.* TO 'appuser'@'10.%';
FLUSH PRIVILEGES;
```

## 초기화

패키지와 관리 설정을 제거하고 데이터는 보존하려면 다음 명령을
사용합니다.

```bash
sudo ./scripts/install.sh --reset
```

데이터까지 삭제하는 명령은 복구할 수 없습니다. 백업을 확인한 후에만
실행하십시오.

```bash
sudo ./scripts/install.sh --reset --delete-data
```

비대화형 `--yes`와 `--delete-data`를 함께 쓰면 추가 확인 없이
`/var/lib/mysql`이 삭제되므로 자동화 파이프라인에서는 사용하지 않는
것을 권장합니다.

신규 설치 전에 존재하지 않았던 `mysql` 시스템 계정과
`SECURE_FILE_PRIV` 디렉터리는 `/var/lib/mariadb-airgap/install.state`에
root 전용 권한으로 기록합니다. `--reset --delete-data`는 이 설치가 직접
생성했다고 기록된 자원만 삭제하며, 기존 계정과 기존 디렉터리는
보존합니다. 초기화가 끝나면 런타임 상태 파일도 제거됩니다.

## Manual Installation & Upgrade

자동 스크립트를 사용할 수 없는 경우 다음 순서로 수동 설치합니다.

```bash
sudo dnf module disable -y mariadb
sudo dnf localinstall -y --disablerepo='*' common/rpms/*.rpm
sudo dnf localinstall -y --disablerepo='*' db/rpms/*.rpm
sudo install -d -o mysql -g mysql -m 750 /var/lib/mysql-files
sudo systemctl enable --now mariadb
sudo mariadb-upgrade --force
```

설정 파일은 `install.conf`의 값을 기준으로
`/etc/my.cnf.d/90-airgap-mariadb.cnf`에 작성한 뒤 서비스를
재시작합니다.

```bash
sudo systemctl restart mariadb
sudo systemctl is-active mariadb
sudo mariadb -NBe "SELECT VERSION();"
```

Galera 클러스터 구성은 노드 순서와 쿼럼 판단이 필요하므로
`galera-cluster-guide.md`를 따르십시오.

## 문제 해결

서비스가 시작되지 않으면 다음 정보를 확인합니다.

```bash
sudo systemctl status mariadb --no-pager -l
sudo journalctl -u mariadb -n 100 --no-pager
sudo mariadbd --verbose --help >/dev/null
```

RPM 의존성 오류가 발생하면 인터넷 연결 호스트와 대상 서버의 OS
버전, 활성 저장소, 아키텍처가 동일한지 확인한 뒤 자산을 다시
수집하십시오.
