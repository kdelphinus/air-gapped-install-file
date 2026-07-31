# MariaDB 10.11.18 Ubuntu 24.04 설치 가이드

## 1. 개요

이 문서는 Ubuntu 24.04 LTS Noble x86_64에 MariaDB 10.11.18과
Galera 4를 온라인 또는 오프라인으로 설치하는 절차를 설명합니다.

설치 스크립트는 다음 버전을 검증합니다.

| 구성 요소 | 패키지 버전 |
|---|---|
| MariaDB | `1:10.11.18+maria~ubu2404` |
| Galera 4 | `26.4.27-ubu2404` |

## 2. 사전 요구 사항

- Ubuntu 24.04 LTS x86_64
- root 또는 sudo 권한
- systemd
- 최소 2 vCPU, 메모리 4GB
- 데이터와 백업 용량을 고려한 디스크
- 온라인 자산 수집 시 MariaDB 및 Ubuntu 저장소 접근

설치 전 OS를 확인합니다.

```bash
cat /etc/os-release
uname -m
systemctl is-system-running
```

## 3. 설치 설정

컴포넌트 루트로 이동합니다.

```bash
cd mariadb-10.11.18-ubuntu24.04
```

설치 전에 `install.conf`를 검토합니다.

```bash
vi install.conf
```

주요 항목은 다음과 같습니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `BIND_ADDRESS` | `0.0.0.0` | MariaDB 수신 주소 |
| `PORT` | `3306` | MariaDB TCP 포트 |
| `MAX_CONNECTIONS` | `1000` | 최대 연결 수 |
| `LOWER_CASE_TABLE_NAMES` | `1` | 테이블명 대소문자 정책 |
| `SECURE_FILE_PRIV` | `/var/lib/mysql-files` | 파일 입출력 허용 경로 |
| `LOCAL_INFILE` | `OFF` | 로컬 파일 적재 허용 여부 |
| `OPEN_FIREWALL` | `false` | 활성 UFW에 포트 규칙 추가 여부 |

`LOWER_CASE_TABLE_NAMES`는 데이터 디렉터리가 초기화된 뒤 변경하면
안 됩니다.

## 4. 온라인 설치

인터넷이 연결된 대상 서버에서는 다음 명령 하나로 DEB 수집과 설치를
진행할 수 있습니다.

```bash
sudo ./scripts/install_online.sh --install --yes
```

이 스크립트는 다음 순서로 동작합니다.

1. MariaDB 10.11.18 보관 저장소와 Ubuntu 저장소에서 DEB를 받습니다.
1. 패키지 버전과 SHA-256 목록을 생성합니다.
1. 로컬 DEB만 사용하는 오프라인 설치 스크립트를 호출합니다.
1. MariaDB 서비스와 실행 버전을 확인합니다.

기존 MariaDB 10.11 계열 업그레이드는 다음과 같이 실행합니다.

```bash
sudo ./scripts/install_online.sh --upgrade --yes
```

업그레이드 전에는 반드시 전체 백업을 생성하십시오.

## 5. 오프라인 설치

### 5.1. 온라인 호스트에서 DEB 수집

인터넷이 연결된 Ubuntu 24.04 x86_64 호스트에서 컴포넌트 루트로
이동합니다.

```bash
cd mariadb-10.11.18-ubuntu24.04
sudo ./scripts/download_assets_offline.sh
```

다운로드 결과는 다음 경로에 저장됩니다.

- `db/debs`: MariaDB, Galera와 재귀 의존성
- `common/debs`: 운영 유틸리티와 재귀 의존성
- `repository`: MariaDB 저장소 서명 키

각 DEB 디렉터리에 `SHA256SUMS`가 생성됩니다.

### 5.2. 오프라인 서버로 전송

컴포넌트 전체를 압축합니다.

```bash
tar -czf mariadb-10.11.18-ubuntu24.04.tar.gz \
  mariadb-10.11.18-ubuntu24.04
```

외장 매체 또는 승인된 내부 전송 경로로 오프라인 서버에 전달합니다.

### 5.3. 오프라인 설치

오프라인 서버에서 압축을 해제하고 컴포넌트 루트로 이동합니다.

```bash
tar -xzf mariadb-10.11.18-ubuntu24.04.tar.gz
cd mariadb-10.11.18-ubuntu24.04
```

DEB와 체크섬 파일이 있는지 확인합니다.

```bash
find db/debs common/debs -maxdepth 1 -type f | sort
```

설치합니다.

```bash
sudo ./scripts/install.sh --install --yes
```

설치 스크립트는 네트워크 다운로드를 금지한 상태로 로컬 DEB만
사용합니다.

## 6. 상태 확인

스크립트로 설치 상태를 확인합니다.

```bash
sudo ./scripts/install.sh --status
```

직접 확인할 수도 있습니다.

```bash
systemctl status mariadb --no-pager
mariadb --version
sudo mariadb -NBe 'SELECT VERSION();'
dpkg-query -W mariadb-server galera-4
```

정상 MariaDB 버전은 `10.11.18-MariaDB`로 시작해야 합니다.

## 7. 재설치

동일 버전의 패키지와 설정을 다시 적용하면서 `/var/lib/mysql`
데이터를 보존합니다.

```bash
sudo ./scripts/install.sh --reinstall --yes
```

## 8. 업그레이드

자동 업그레이드는 기존 MariaDB 10.11 계열에서만 지원합니다.

```bash
sudo ./scripts/install.sh --upgrade --yes
```

설치된 버전이 10.11.18보다 최신이면 스크립트는 다운그레이드를
거부합니다.

## 9. 제거 및 초기화

### 9.1. 데이터 보존 제거

MariaDB와 Galera 패키지 및 관리 설정을 제거하고 데이터는
보존합니다.

```bash
sudo ./scripts/install.sh --reset --yes
```

### 9.2. 데이터 포함 제거

다음 명령은 `/var/lib/mysql`을 삭제합니다.

```bash
sudo ./scripts/install.sh --reset --delete-data --yes
```

이 작업은 복구할 수 없으므로 백업을 먼저 확인하십시오.

## 10. Manual Installation & Upgrade

자동 스크립트를 사용할 수 없는 환경의 수동 절차입니다.

### 10.1. DEB 체크섬 확인

```bash
cd mariadb-10.11.18-ubuntu24.04
(cd db/debs && sha256sum -c SHA256SUMS)
(cd common/debs && sha256sum -c SHA256SUMS)
```

### 10.2. 수동 오프라인 설치

검증된 DEB로 임시 로컬 APT 저장소를 생성합니다.

```bash
sudo install -d -m 755 /opt/mariadb-local-repo
sudo cp common/debs/*.deb db/debs/*.deb /opt/mariadb-local-repo/
sudo bash -c '
  cd /opt/mariadb-local-repo
  : > Packages
  for deb in ./*.deb; do
    dpkg-deb -f "$deb" >> Packages
    printf "Filename: %s\nSize: %s\nSHA256: %s\n\n" \
      "$deb" \
      "$(stat -Lc %s "$deb")" \
      "$(sha256sum "$deb" | awk "{print \$1}")" >> Packages
  done
'
echo \
  'deb [trusted=yes] file:/opt/mariadb-local-repo ./' |
  sudo tee /tmp/mariadb-local.list
sudo apt-get \
  -o Dir::Etc::sourcelist=/tmp/mariadb-local.list \
  -o Dir::Etc::sourceparts=- \
  update
```

패키지가 데이터 디렉터리를 처음 초기화하기 전에 설정 파일과 보안
파일 경로를 생성합니다.

```bash
sudo install -d -m 755 /etc/mysql/mariadb.conf.d
sudo install -d -m 755 /var/lib/mysql-files
sudo tee /etc/mysql/mariadb.conf.d/90-airgap-mariadb.cnf >/dev/null <<'EOF'
[mariadb]
bind-address=0.0.0.0
port=3306
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-storage-engine=InnoDB
binlog-format=ROW
innodb-autoinc-lock-mode=2
lower-case-table-names=1
max-connections=1000
secure-file-priv=/var/lib/mysql-files
local-infile=OFF
EOF
```

정확한 버전을 로컬 저장소에서 설치합니다.

```bash
sudo systemctl stop mariadb 2>/dev/null || true
sudo env DEBIAN_FRONTEND=noninteractive apt-get \
  -o Dir::Etc::sourcelist=/tmp/mariadb-local.list \
  -o Dir::Etc::sourceparts=- \
  install -y --no-install-recommends \
  mysql-common=1:10.11.18+maria~ubu2404 \
  mariadb-common=1:10.11.18+maria~ubu2404 \
  libmariadb3=1:10.11.18+maria~ubu2404 \
  mariadb-client-core=1:10.11.18+maria~ubu2404 \
  mariadb-client=1:10.11.18+maria~ubu2404 \
  mariadb-server-core=1:10.11.18+maria~ubu2404 \
  mariadb-server=1:10.11.18+maria~ubu2404 \
  mariadb-backup=1:10.11.18+maria~ubu2404 \
  galera-4=26.4.27-ubu2404
```

서비스와 시스템 테이블을 확인합니다.

```bash
sudo install -d -o mysql -g mysql -m 750 /var/lib/mysql-files
sudo systemctl enable --now mariadb
sudo mariadb-upgrade --force
sudo mariadb -NBe 'SELECT VERSION();'
```
### 10.3. 수동 온라인 설치

MariaDB 보관 저장소를 등록한 뒤 정확한 패키지 버전을 지정합니다.

```bash
curl -fsSL \
  https://mariadb.org/mariadb_release_signing_key.pgp \
  -o /tmp/mariadb-key.pgp
gpg --dearmor < /tmp/mariadb-key.pgp |
  sudo tee /usr/share/keyrings/mariadb-keyring.gpg >/dev/null
echo \
  'deb [arch=amd64 signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://archive.mariadb.org/mariadb-10.11.18/repo/ubuntu noble main' |
  sudo tee /etc/apt/sources.list.d/mariadb-10.11.18.list
sudo apt-get update
sudo apt-get install -y \
  mariadb-server=1:10.11.18+maria~ubu2404 \
  mariadb-client=1:10.11.18+maria~ubu2404 \
  mariadb-backup=1:10.11.18+maria~ubu2404 \
  galera-4=26.4.27-ubu2404
```

## 11. 문제 해결

서비스 로그를 확인합니다.

```bash
sudo journalctl -u mariadb -n 200 --no-pager
```

패키지 상태를 확인합니다.

```bash
sudo dpkg --audit
apt-cache policy mariadb-server galera-4
```

사용자 지정 `SECURE_FILE_PRIV`에서 접근 거부가 발생하면 기본 경로로
되돌리거나 조직의 AppArmor 정책에 해당 경로를 추가하십시오.
