# ArgoCD v2.12.1 오프라인 설치 명세

본 문서는 오프라인(폐쇄망) 환경에서 ArgoCD v2.12.1을 안정적으로 배포하고 멱등 관리하기 위한 명세를 정의합니다.

---

## 📌 버전 정보 명세

* **Helm Chart Version**: `7.4.1` (argo-cd)
* **App Version**: `v2.12.0`
* **Container Image Version**: `v2.12.1`
* **대상 OS**: Rocky Linux 9.6 / Ubuntu 24.04

---

## 📦 포함 컨테이너 이미지

| 이미지명 | 태그 | 용도 | 비고 |
| :--- | :--- | :--- | :--- |
| `quay.io/argoproj/argocd` | `v2.12.1` | ArgoCD 핵심 컴포넌트 | 서버, 컨트롤러, repo-server, applicationSet 등 |
| `public.ecr.aws/docker/library/redis` | `7.2.4-alpine` | ArgoCD 캐시 스토리지 | 기본 Standalone 캐시 데이터베이스 |
| `public.ecr.aws/docker/library/haproxy` | `2.9-alpine` | Redis HA 프록시 | **[예비 자산]** Redis HA(다중화) 다중화 구성 시 사용 |
| `docker.io/koalaman/shellcheck` | `v0.5.0` | 헬름 테스트 훅 | **[예비 자산]** Redis HA 모드 시 Helm test 훅 지원용 |

---

## 📁 디렉토리 구조

```text
argocd-2.12.1/
├── charts/
│   └── argo-cd/                        # Helm 차트 원본 (Chart version 7.4.1)
├── images/
│   └── upload_images_to_harbor_v3-lite.sh  # 에어갭 이미지 마이그레이션 도구 (본체)
├── manifests/
│   └── nas-pv.yaml                     # NAS(NFS) 정적 볼륨 구성 시 PV/PVC 정의
├── scripts/
│   ├── download_assets_offline.sh      # 에셋 수집 도구 (차트 pull 및 이미지 export)
│   ├── install.sh                      # 대화형 멱등 설치 스크립트
│   └── uninstall.sh                    # 멱등 삭제 및 초기화 스크립트
├── values.yaml                         # 기본 Helm 설정 (Dex 비활성화 및 기본값)
├── install.conf                        # 설치 인프라 설정 파일 (자동 생성)
├── values-infra.yaml                   # 인프라 오버라이드 설정 파일 (자동 생성)
├── README.md                           # 서비스 설명서
└── install-guide.md                    # 상세 설치 가이드
```

---

## 🛠️ 스토리지 구성

| 스토리지 타입 | 설명 |
| :--- | :--- |
| **none** | 영구 저장소 없음 (재시작 시 캐시 초기화) |
| **hostpath** | 노드 호스트 경로 기반 저장 (기본값) |
| **nas** | NFS 기반 NAS 저장 (정적 PV/PVC 할당) |
| **nfs-dynamic** | NFS 기반 동적 할당 (StorageClass 필요) |

---

## 🔌 네트워크 접속 정보

* **NodePort:** `http://<NODE_IP>:30001`
* **HTTPRoute (도메인):** `http://argocd.devops.internal` (Envoy Gateway 연동 시 생성)

상세 설치 가이드 및 장애 테스트는 **[install-guide.md](./install-guide.md)**를 참조하세요.
