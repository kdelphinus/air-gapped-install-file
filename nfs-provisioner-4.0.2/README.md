# NFS Subdir External Provisioner v4.0.2 (Chart 4.0.18 / App v4.0.2)

NFS 스토리지를 백엔드로 사용하여 Kubernetes 상에서 동적 볼륨 프로비저닝(Dynamic Provisioning)을 제공하는 서비스입니다. 특히 **NetApp 스토리지의 NFS v4.1 최적화** 및 **다중 StorageClass 운영**에 최적화되어 있습니다.

---

## 🚀 주요 특징

* **NFS v4.1 지원**: Session Trunking 및 고가용성을 위한 최적화 마운트 옵션 적용.
* **다중 StorageClass**: 애플리케이션용(`nfs-app`), 백업용(`nfs-backup`), 테스트용(`nfs-test`) 등으로 논리적 경로 분리 운영 가능.
* **대화형 멱등 설치**: `install.sh`를 통해 자산 자동 사전 검증 및 설정을 동기화하여 재설치/업그레이드를 멱등 제어.
* **보안성 및 설정 보존**: `install.conf` 및 `values-infra.yaml`을 활용하여 인프라 설정 구성을 안전하게 영구 보존.

---

## 📁 디렉토리 구조

```text
nfs-provisioner-4.0.2/
├── charts/                     # Helm Chart (nfs-subdir-external-provisioner)
├── images/
│   ├── download_assets_offline.sh
│   └── upload_images_to_harbor_v3-lite.sh  # 에어갭 이미지 마이그레이션 도구
├── manifests/
│   ├── additional-sc.yaml      # 추가 StorageClass 설정 (backup, test 등)
│   └── nfs-provisioner.yaml    # 수동 설치용 정적 리소스 템플릿
├── scripts/
│   ├── install.sh              # 대화형 멱등 설치 스크립트
│   └── uninstall.sh            # 멱등 삭제 및 초기화 스크립트
├── values.yaml                 # 기본 Helm 설정 (v4.1 최적화 포함)
├── README.md                   # 서비스 설명서
└── install-guide.md            # 상세 설치 가이드
```

---

## 🛠 설치 요약

1. **에셋 수집 및 이식:**
   ```bash
   # 외부망 에셋 수집
   ./scripts/download_assets_offline.sh
   # 폐쇄망 이미지 로드
   ./images/upload_images_to_harbor_v3-lite.sh
   ```

2. **설치 기동:**
   ```bash
   # 대화형 멱등 설치
   ./scripts/install.sh
   ```

상세 설치 가이드 및 장애 테스트는 **[install-guide.md](./install-guide.md)**를 참조하세요.
