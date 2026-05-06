# Git v2.43.0 오프라인 설치 명세

본 문서는 **Rocky Linux 9.6** 폐쇄망 환경을 위한 Git 패키지 구성 명세를 정의합니다.

## 버전 정보

| 항목 | 사양 | 비고 |
| :--- | :--- | :--- |
| **OS** | Rocky Linux 9.6 (Blue Onyx) | RHEL 계열 |
| **Git Version** | **2.43.0** | Standard Stable |
| **번들 파일명** | `git_bundle_rocky96_YYYYMMDD.tar.gz` | 날짜 포함 |

## 포함 패키지

- `git` 2.43.0 및 의존성 RPM 일체
- 추가 유틸리티: `zip`, `unzip`, `tar`, `net-tools`, `curl`, `wget`

## 디렉토리 구조

| 파일/경로 | 설명 |
| :--- | :--- |
| `export_git_rpms.sh` | 외부망에서 RPM 다운로드 및 번들 생성 스크립트 |
| `git_bundle_rocky96_*.tar.gz` | 오프라인 설치용 RPM 번들 (압축) |
