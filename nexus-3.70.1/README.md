# 📦 Nexus Repository Manager v3.70.1

폐쇄망 환경에서 라이브러리(Maven, NPM, PyPI 등)를 중앙 관리하는 아티팩트 저장소입니다.

## 📦 구성 요소

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | Nexus Helm 차트 |
| `images/` | Nexus3 공식 이미지 |
| `scripts/` | 오프라인 에셋 다운로드 스크립트 |

## 🛠️ 주요 설정 (변수화)

### 1. Registry (Harbor)
- `values.yaml` 내 `image.repository`

### 2. Storage Strategy
- **NFS (추천)**: 여러 노드에서 데이터 접근이 용이하며 백업이 쉽습니다.
- **HostPath**: 단일 노드 기반 설치 시 사용합니다.

### 3. JVM 최적화
- `values.yaml` 내 `nexus.env`에서 힙 메모리를 조절할 수 있습니다.

## 💡 운영 팁 (오프라인 라이브러리 반입)

- **Proxy Repository**: 폐쇄망에서는 외부와 통신이 안 되므로 Proxy가 아닌 **Hosted Repository**를 주로 사용합니다.
- **Bulk Upload**: 외부에서 다운로드한 `.jar`, `.tar.gz` 등을 Nexus REST API나 전용 도구를 사용하여 일괄 업로드해야 합니다.
