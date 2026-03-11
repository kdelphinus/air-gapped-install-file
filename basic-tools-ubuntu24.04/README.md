# Basic Tools 오프라인 설치 명세 (Ubuntu 24.04)

본 문서는 **Ubuntu 24.04** 폐쇄망 환경에 필수 기본 도구를 설치하기 위한 패키지 구성 명세를 정의합니다.

## 버전 정보

| 항목 | 사양 |
| :--- | :--- |
| **대상 OS** | Ubuntu 24.04 LTS |
| **패키지 형식** | DEB (`.deb`) |

## 포함 도구

| 분류 | 도구 |
| :--- | :--- |
| **네트워킹** | `curl`, `wget`, `net-tools` (ifconfig, netstat), `dnsutils` (dig, nslookup), `telnet`, `rsync` |
| **파일 관리** | `zip`, `unzip`, `tar`, `lsof` |
| **유틸리티** | `vim`, `jq` |

## 디렉토리 구조

| 파일/경로 | 설명 |
| :--- | :--- |
| `export_basic_tools.sh` | 외부망에서 DEB 다운로드 및 번들 생성 스크립트 |
| `install_tools.sh` | 폐쇄망 서버에서 DEB 일괄 설치 스크립트 |
| `basic_tools_bundle_ubuntu/` | DEB 패키지 번들 디렉토리 |
| `basic_tools_ubuntu2404_YYYYMMDD.tar.gz` | 오프라인 설치용 DEB 번들 (압축) |

## 참고

- `dpkg -i` 명령어로 DEB 패키지를 설치합니다.
- `export_basic_tools.sh` 는 `apt-cache depends` 를 이용해 의존성 DEB까지 함께 다운로드합니다.
