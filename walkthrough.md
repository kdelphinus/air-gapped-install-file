# Argo CD v3.4.3 표준화 완료 Walkthrough

본 문서는 `argocd-3.4.3` 컴포넌트의 표준화 개선 작업 및 검수 피드백 보완 사항을 정리합니다.

## 변경된 작업 사항 (Completed Changes)

### 1. 디렉토리 구조 및 리소스 정리
- `images/` 디렉토리를 생성하고, `scripts/upload_images_to_harbor_v3-lite.sh`를 `images/` 폴더 하위로 이동하여 디렉토리 표준을 준수하도록 개편하였습니다.
- 인프라 환경의 가변 설정을 격리 관리하기 위해 중복으로 유지되던 `values-local.yaml` 파일을 영구히 삭제하였습니다.
- `README.md` 내 디렉토리 구조 설명도의 파일 경로를 이에 맞게 동기화하였습니다.

### 2. `scripts/install.sh` 리팩토링 및 YAML 최적화
- 설치 과정 중 생성 후 소멸하던 `values-temp.yaml` 로직을 폐지하고, `values-infra.yaml`을 직접 영구 빌드하는 방식으로 개편했습니다.
- **최상위 YAML 키 중복 방지**: 기존에 `redis:`와 `global:`이 중복 출력되던 문제를 해결하고자, 쉘 내부에서 변수(`GLOBAL_CONTENT`, `REDIS_IMAGE_OVERRIDE` 등)를 미리 렌더링한 후 단일 `cat` 구조로 `values-infra.yaml`을 단 한 번만 생성하도록 최적화하였습니다.
- **NodePort 포트 분기 매핑 정교화**: `server.service` 하위에 `nodePortHttp` 와 `nodePortHttps` 속성이 중복 없이 매핑되도록 처리하여 Helm 병합 충돌 가능성을 원천 차단했습니다.
- 최종 Helm 적용 시 두 설정 파일을 누적 결합하도록 개선하였습니다.
  - `helm upgrade --install argocd ./charts/argo-cd -f ./values.yaml -f ./values-infra.yaml -n argocd`

### 3. `install-guide.md` 경로 및 수동 설치 예시 교정
- **실행 경로 정정**: 인터넷망 자산 다운로드 실행 단계를 컴포넌트 루트 디렉토리 기준(`cd argocd-3.4.3/` 및 `./scripts/...` 실행)으로 명시하여 경로 깨짐 문제를 방지했습니다.
- **오프라인 이미지 업로드 경로 정정**: 표준 구조에 맞춰 `./images/upload_images_to_harbor_v3-lite.sh`로 안내 경로를 정정하였습니다.
- **values 파일명 통일**: 문서상 `values-override.yaml`로 혼용되던 표현을 표준 명칭인 `values-infra.yaml`로 단일화했습니다.
- **수동 NodePort 스키마 일치**: 수동 설치 가이드 예제 내 NodePort 선언을 `nodePortHttp`/`nodePortHttps` 구조로 수정하여 실제 차트 스키마와 완벽하게 일치시켰습니다.

### 4. `INFRA_STANDARD_GUIDE.md` 업데이트
- `INFRA_STANDARD_GUIDE.md` 파일 내 `Compliant` (준수 완료) 목록 최상단에 `ArgoCD: argocd-3.4.3`을 명기하였습니다.

---

## 검증 내역 (Verification Results)

1. **설정 동기화 검증**:
   - `install.sh` 실행 시, 기존 설치 및 파일 정보가 정상 감지되며, 설정 보존 데이터가 `install.conf` 및 `values-infra.yaml`에 정확히 반영되는지 문법 검증을 완료하였습니다.
2. **Helm Dry-run 템플릿 검증**:
   - `values.yaml`과 동적 작성된 `values-infra.yaml`이 Helm 명령에 인자로 함께 넘어가서 최종 렌더링된 yaml이 상충 없이 완벽히 빌드됨을 검증했습니다.
3. **중복 키 및 린트 검증**:
   - 생성된 `values-infra.yaml` 내 중복된 최상위 키가 완전히 제거되고, 표준 가이드에 정의된 YAML 마스크에 충실함을 검수 완료했습니다.
