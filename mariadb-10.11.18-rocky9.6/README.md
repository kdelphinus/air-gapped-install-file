# MariaDB 10.11.18 설치 패키지

Rocky Linux 9 계열 x86_64 서버에 MariaDB 10.11.18과 Galera 4
26.4.27 패키지를 온라인 또는 오프라인으로 설치하기 위한 구성입니다.

## 지원 범위

- 단일 노드 MariaDB 10.11.18 신규 설치
- MariaDB 10.11 계열에서 10.11.18로 업그레이드
- 동일 버전 재설치 시 기존 데이터 보존
- 설치 설정의 `install.conf` 영속화
- Galera 3노드의 노드별 설정, 신규 부트스트랩 및 조인 지원
- Galera 전체 장애 복구 수동 절차 제공

## 디렉터리 구조

```text
mariadb-10.11.18-rocky9.6/
├── common/rpms/
├── db/rpms/
├── scripts/
│   ├── configure_galera.sh
│   ├── download_assets_offline.sh
│   ├── install_online.sh
│   └── install.sh
├── galera.conf
├── galera-cluster-guide.md
├── install-guide.md
└── install.conf
```

`install.conf`과 `galera.conf`에는 비밀번호를 저장하지 않습니다. 초기
보안 설정과 애플리케이션 계정 생성은 설치 후 로컬 소켓으로 직접
수행하십시오.

## 빠른 시작

온라인 서버에 바로 설치합니다.

```bash
sudo ./scripts/install_online.sh --install
```

인터넷 연결 호스트에서 오프라인용 RPM을 수집합니다.

```bash
sudo ./scripts/download_assets_offline.sh
```

폴더 전체를 폐쇄망 서버로 반입한 뒤 설치합니다.

```bash
sudo ./scripts/install.sh --install
```

세부 절차와 검증 방법은 `install-guide.md`를 참조하십시오. Galera
구성과 안전한 실행 순서는 `galera-cluster-guide.md`를 따르십시오.
