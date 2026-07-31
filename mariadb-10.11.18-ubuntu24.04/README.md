# MariaDB 10.11.18 for Ubuntu 24.04

Ubuntu 24.04 LTS Noble x86_64에 MariaDB 10.11.18과 Galera 4를
온라인 또는 오프라인으로 설치하는 구성입니다.

## 지원 범위

- MariaDB Server, Client, Backup `1:10.11.18+maria~ubu2404`
- Galera 4 `26.4.27-ubu2404`
- 온라인 설치용 DEB 자동 수집
- 완전 오프라인 DEB 설치
- 설치, 10.11 계열 업그레이드, 재설치, 상태 확인, 초기화
- 기존 데이터 보존 재설치
- 명시적 확인을 거친 데이터 삭제
- Galera 3노드 이상 구성, 부트스트랩, 조인, 상태 확인

## 디렉터리 구조

```text
mariadb-10.11.18-ubuntu24.04/
├── common/
│   └── debs/
├── db/
│   └── debs/
├── repository/
├── scripts/
│   ├── configure_galera.sh
│   ├── download_assets_offline.sh
│   ├── install_online.sh
│   └── install.sh
├── galera-cluster-guide.md
├── galera.conf
├── install-guide.md
└── install.conf
```

`install.conf`과 `galera.conf`에는 비밀번호를 저장하지 않습니다.

## 빠른 시작

온라인 설치는 컴포넌트 루트에서 실행합니다.

```bash
sudo ./scripts/install_online.sh --install --yes
```

오프라인 자산 수집은 인터넷이 연결된 Ubuntu 24.04 x86_64에서
실행합니다.

```bash
sudo ./scripts/download_assets_offline.sh
```

컴포넌트 전체를 오프라인 서버로 복사한 뒤 설치합니다.

```bash
sudo ./scripts/install.sh --install --yes
```

Galera 구성은 모든 노드에 MariaDB 설치가 끝난 뒤 진행합니다.

```bash
sudo ./scripts/configure_galera.sh --help
```

세부 절차는 [install-guide.md](install-guide.md)와
[galera-cluster-guide.md](galera-cluster-guide.md)를 참고하십시오.

## 주의 사항

- Ubuntu 기본 저장소가 아닌 MariaDB 10.11.18 보관 저장소를 사용합니다.
- DEB 파일은 Git 정책에 따라 커밋하지 않고 다운로드 스크립트로
  생성합니다.
- `LOWER_CASE_TABLE_NAMES`는 데이터 디렉터리 초기화 이후 임의로
  변경하지 마십시오.
- `SECURE_FILE_PRIV`를 기본 경로 밖으로 바꾸면 별도 AppArmor 정책이
  필요할 수 있습니다.
- Galera 신규 부트스트랩은 첫 번째 노드 한 대에서만 실행하십시오.
