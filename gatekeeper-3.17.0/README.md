# Gatekeeper v3.17.0

Gatekeeper는 Kubernetes admission control과 audit 기능을 통해 OPA 기반 정책을 적용하는 컴포넌트입니다.
본 디렉터리는 폐쇄망 환경에서 Gatekeeper v3.17.0을 설치하기 위한 Helm 차트, 이미지, 스크립트, 문서를 보관합니다.

## 구성

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | Gatekeeper Helm 차트 오프라인 보관 위치 |
| `images/` | Gatekeeper 컨테이너 이미지 tar 파일과 Harbor 업로드 스크립트 |
| `scripts/` | 자산 다운로드, 설치, 제거 스크립트 |
| `values.yaml` | Harbor 레지스트리 기반 설치 값 |
| `values-local.yaml` | 로컬 containerd 이미지 직접 사용 설치 값 |
| `install-guide.md` | 단계별 설치 및 수동 설치 절차 |

## 설치

```bash
sudo ./scripts/install.sh
```

설치 스크립트는 이미지 소스(Harbor 또는 로컬 tar)를 선택받고 `install.conf`에 설정을 저장합니다.
기존 설치 또는 설정 파일이 감지되면 업그레이드, 재설치, 초기화 메뉴를 제공합니다.

자세한 절차는 [install-guide.md](./install-guide.md)를 참고하십시오.
