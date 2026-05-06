# Docker Engine 29.1.5 오프라인 설치 명세

본 문서는 **Docker Engine 29.1.5** 폐쇄망 오프라인 설치를 위한 파일 구성 및 스펙을 정의합니다.

## 버전 정보

| 항목 | 사양 | 비고 |
| :--- | :--- | :--- |
| **Docker Engine** | **29.1.5** | CE (Community Edition) |
| **설치 방식** | RPM 패키지 / Static Binary | 두 가지 방법 제공 |
| **대상 OS** | Rocky Linux 9.6 (RHEL 계열) | RPM 기반 |

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `rpm/` | Docker Engine RPM 패키지 및 의존성 파일 |
| `static/` | Static Binary 배포본 (`docker-*.tgz`) |

## 설치 파일 구성

### RPM 방식 (권장)

- `rpm/` 디렉토리 내 Docker Engine 및 의존성 `.rpm` 파일 일체
- `dnf` 를 이용한 로컬 일괄 설치 지원

### Static Binary 방식 (비상용)

- `static/docker-*.tgz` — 실행 파일 묶음
- RPM 설치 실패 시 대안으로 사용

## 참고

- RPM 방식이 systemd 서비스 등록, 자동 시작 등 운영 측면에서 권장됨
- Static Binary 방식은 systemd service 파일을 별도로 등록해야 정식 운영 가능
