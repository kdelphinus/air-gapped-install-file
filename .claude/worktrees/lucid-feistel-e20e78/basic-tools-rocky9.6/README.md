# Basic Tools 오프라인 설치 명세 (Rocky Linux 9.6)

본 문서는 **Rocky Linux 9.6** 폐쇄망 환경에 필수 기본 도구를 설치하기 위한 패키지 구성 명세를 정의합니다.

## 포함 도구

| 분류 | 도구 |
| :--- | :--- |
| **네트워킹** | `curl`, `wget`, `net-tools` (ifconfig, netstat), `bind-utils` (dig, nslookup), `telnet`, `rsync` |
| **파일 관리** | `zip`, `unzip`, `tar`, `lsof` |
| **유틸리티** | `vim`, `jq` |

## 디렉토리 구조

| 파일 | 설명 |
| :--- | :--- |
| `export_basic_tools.sh` | 외부망에서 RPM 다운로드 및 번들 생성 스크립트 |
| `install_tools.sh` | 폐쇄망 서버에서 RPM 일괄 설치 스크립트 |
| `basic_tools_rocky96_YYYYMMDD.tar.gz` | 오프라인 설치용 RPM 번들 (압축) |

## 참고

- `rpm -Uvh` 명령어로 이미 설치된 패키지는 업데이트하거나 그대로 유지합니다.
- `export_basic_tools.sh` 는 의존성 RPM까지 함께 다운로드합니다.
