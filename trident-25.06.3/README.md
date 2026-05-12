# NetApp Trident 25.06.3

NetApp Trident는 Kubernetes를 위한 동적 스토리지 오케스트레이터로, NetApp ONTAP 등 다양한 스토리지 백엔드와의 통합을 지원합니다. 이 저장소는 폐쇄망(Air-gapped) 환경에서의 안정적인 배포를 위한 설정과 스크립트를 포함하고 있습니다.

## 주요 기능

- **동적 프로비저닝**: PVC 요청에 따른 자동 볼륨 생성.
- **ONTAP 통합**: NAS(NFS) 및 SAN(iSCSI) 드라이버 지원.
- **오프라인 최적화**: 로컬 차트 및 이미지 참조를 통한 설치 지원.

## 디렉토리 구조

- `charts/`: Trident Operator Helm 차트 저장 (오프라인 배포용).
- `images/`: 컨테이너 이미지 아카이브 및 Harbor 업로드 스크립트.
- `manifests/`: Trident Backend Config 및 StorageClass 정의.
- `scripts/`: 설치, 재설치 및 초기화용 통합 스크립트.
- `values.yaml`: Helm 설치 시 적용되는 기본 설정값.

## 설치 및 운영

상세한 설치 방법 및 수동 설치 절차는 [install-guide.md](install-guide.md)를 참조하십시오.
