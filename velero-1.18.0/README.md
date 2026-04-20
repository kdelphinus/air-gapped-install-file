# Velero v1.18.0 Offline Installation

이 폴더는 폐쇄망 환경에서 Kubernetes 클러스터의 백업 및 복구를 수행하기 위한 Velero 설치 에셋을 포함합니다.

## 구성 요소

- **Velero CLI**: v1.18.0
- **Velero Helm Chart**: v12.0.0
- **MinIO**: RELEASE.2024-12-18T13-15-44Z (전용 백업 스토리지)
- **MinIO Client (mc)**: RELEASE.2024-11-21T17-21-54Z

## 디렉토리 구조

```text
velero-1.18.0/
├── charts/          # Velero 헬름 차트
├── images/          # .tar 이미지 파일 및 Harbor 업로드 스크립트
├── manifests/       # MinIO 배포용 매니페스트
├── scripts/         # 설치 및 에셋 다운로드 스크립트
├── values.yaml      # Harbor용 헬름 설정
├── values-local.yaml # 로컬 이미지용 헬름 설정
└── install-guide.md # 상세 설치 가이드
```

## 빠른 시작

1. `scripts/download_assets.sh`를 실행하여 모든 에셋을 다운로드합니다.
2. 에셋을 폐쇄망으로 반입한 뒤, `install-guide.md`를 참고하여 설치를 진행합니다.
3. Harbor 사용 시 `scripts/install.sh`의 IP를 수정한 후 실행하십시오.

상세한 설치 및 운영 방법은 [install-guide.md](./install-guide.md)를 참조하십시오.
