# NFS Subdir External Provisioner v4.0.18

NFS 스토리지를 백엔드로 사용하여 쿠버네티스에서 동적 볼륨 프로비저닝(Dynamic Provisioning)을 제공하는 서비스입니다. 특히 **NetApp 스토리지의 NFS v4.1 최적화** 및 **다중 StorageClass 운영**에 최적화되어 있습니다.

## 🚀 주요 특징
- **NFS v4.1 지원**: Session Trunking 및 고가용성을 위한 최적화 옵션 적용.
- **다중 StorageClass**: 애플리케이션용, 백업용, 테스트용 등으로 논리적 경로 분리 운영 가능.
- **대화형 설치**: `install.sh`를 통해 NFS 정보만 입력하면 자동 설치.

## 📁 디렉토리 구조
```text
nfs-provisioner-4.0.18/
├── charts/             # Helm Chart (nfs-subdir-external-provisioner)
├── images/             # 컨테이너 이미지 (.tar)
├── manifests/          # 추가 StorageClass 설정 (backup, test 등)
├── scripts/
│   └── install.sh      # 대화형 설치 스크립트
├── values.yaml         # 기본 Helm 설정 (v4.1 최적화 포함)
├── install.conf        # 설치 설정 저장 파일 (자동 생성)
├── README.md           # 서비스 설명서
└── install-guide.md    # 상세 설치 가이드
```

## 🛠 설치 요약
1. `scripts/install.sh` 실행
2. NFS 서버 IP 및 경로 입력
3. 설치 완료 후 `kubectl get sc`로 StorageClass 확인

상세 내용은 [install-guide.md](./install-guide.md)를 참조하세요.
