# NFS Provisioner v4.0.2 오프라인 설치 명세

본 문서는 **nfs-subdir-external-provisioner v4.0.2** 기반의 Kubernetes 동적 스토리지 프로비저닝 구성 명세를 정의합니다.

## 버전 정보

| 항목 | 사양 | 비고 |
| :--- | :--- | :--- |
| **Provisioner** | nfs-subdir-external-provisioner v4.0.2 | NFS 동적 프로비저닝 |
| **컨테이너 이미지** | `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2` | `.tar` 로 반입 |
| **멀티 OS 지원** | Rocky Linux / RHEL, Ubuntu | OS별 스크립트 분리 |

## 구성 요소

| 리소스 | 설명 |
| :--- | :--- |
| RBAC | ClusterRole / ClusterRoleBinding / ServiceAccount |
| Deployment | nfs-subdir-external-provisioner Pod |
| StorageClass | 동적 PVC 할당용 스토리지 클래스 |

## 네트워크 요구사항

| 포트 | 프로토콜 | 용도 |
| :--- | :--- | :--- |
| 2049 | TCP/UDP | NFS 마운트 |
| 111 | TCP/UDP | RPC portmapper |

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `manifests/nfs-provisioner.yaml` | RBAC + Deployment + StorageClass 통합 매니페스트 |
| `scripts/ubuntu/` | Ubuntu용 패키지 다운로드 및 설치 스크립트 |
| `scripts/rhel_rocky/` | RHEL / Rocky Linux용 패키지 다운로드 및 설치 스크립트 |
| `scripts/load_image.sh` | 컨테이너 런타임별 이미지 로드 스크립트 |
| `nfs-packages/` | 오프라인 설치용 OS 패키지 보관 디렉토리 |

## 스토리지 정책 참고

| 항목 | 직접 구축 (In-cluster) | 외부 NAS (Managed) |
| :--- | :--- | :--- |
| 자율성 | 인프라 팀 협조 없이 즉시 구축 가능 | 인프라 팀 정책에 종속 |
| 운영 부담 | NFS 서버 소프트웨어 직접 관리 | 저장소 안정성은 인프라 팀이 책임 |
| 성능 | 워커 노드의 네트워크/디스크 성능 공유 | 전용 스토리지 네트워크 사용 가능 |
