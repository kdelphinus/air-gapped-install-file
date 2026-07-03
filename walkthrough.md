# Walkthrough: Harbor v2.10.3 표준화 및 오프라인 배포 개선

본 문서는 `harbor-2.10.3` 컴포넌트를 에어갭 환경 및 인프라 표준 규격에 맞게 리팩토링한 작업 내역과 검증 결과를 상세히 기록합니다.

---

## 1. 주요 변경 내역 요약 (Changes)

### 📂 디렉토리 구조 및 중복 정리
- **중복 스크립트 삭제**: `scripts/`와 `images/`에 중복 존재하던 `upload_images_to_harbor_v3-lite.sh` 중 `scripts/` 하위 본을 삭제(`git rm`)하고 `images/upload_images_to_harbor_v3-lite.sh`로 참조를 통일했습니다.
- **불필요한 설정 파일 정리**: 로컬용 이미지 수동 import 설정들이 엉켜있던 `values-local.yaml` 파일을 영구 삭제하고, 해당 리소스 최소화 옵션을 `install.sh` 내부에 유기적으로 통합했습니다.
- **`.gitignore` 갱신**: 가변 인프라 설정 결과물인 `values-infra.yaml` 및 `manifests/*-infra.yaml`을 Git 추적에서 제외하여 설정 오염을 방지했습니다.

### ⚙️ 멱등성 및 생명주기 관리 (`install.sh`, `uninstall.sh`)
- **`install.conf` 저장 체계 마련**: 비밀번호를 제외한 가변 인프라 설정들(IP, 도메인, 스토리지 크기, 노드 포트 등)을 저장하고 재활용하도록 리팩토링했습니다.
- **비밀번호 보안성 확보**: 평문 비밀번호 저장을 절대 지양하고, `Upgrade` 시 기존 K8s Secret에서 패스워드를 상속받아 구동되도록 지능화했습니다.
- **PV 데이터 물리적 보호**: Reset 또는 Reinstall 시에도 실제 이미지들이 담긴 PV/PVC의 삭제 여부는 별도의 인터랙티브 y/N 프롬프트를 거쳐 사용자 확인 하에 제거되도록 고안했습니다.
- **`values-infra.yaml` 런타임 빌드**: 쉘 변수를 미리 병합하여 YAML 최상위 키 중복 덮어쓰기 현상을 원천 방지하고, 리소스 최소화(`MINIMIZE_RESOURCES`) 옵션을 포함하여 한 번에 조립해 출력하는 구조로 개편했습니다.

### 📝 명세 및 설명서 교정
- **`README.md` & `install-guide.md`**: 이미지 업로드 스크립트의 경로를 `images/` 하위로 통일하고, `install.sh` 구동 흐름 및 수집 파라미터 설명을 최신 스크립트 아키텍처에 부합하게 수정했습니다.
- **마크다운 린트 규칙 준수**: 헤더 빈 줄 및 공백 정리 작업을 완료했습니다.

---

## 2. 검증 수행 내역 (Verification Results)

### 1) 쉘 스크립트 문법 정합성 검증 (`bash -n`)
WSL(rocky) 가상 환경 내에서 모든 쉘 파일의 문법적 오류가 존재하지 않음을 확인했습니다.
```bash
wsl -d rocky -e bash -c "cd /home/mjko/air-gapped-install-file && bash -n harbor-2.10.3/scripts/install.sh && bash -n harbor-2.10.3/scripts/uninstall.sh"
# -> Output: (아무런 구문 결함이 검출되지 않고 정상 종료)
```

### 2) Git Diff 서식 검증 (`git diff --check`)
공백 문자나 마크다운 서식 결함이 없음을 확인했습니다.
```bash
git diff --check
# -> Output: (서식 결함 검출되지 않음)
```

### 3) Helm template을 통한 K8s 매니페스트 빌드 검증
컴포넌트 루트 기준으로 임시 `values-infra.yaml`을 생성하여 Helm 빌드 정합성을 검증했습니다.
```bash
helm template harbor ./charts/harbor -n harbor -f ./values.yaml -f ./values-infra.yaml
```
- **검증 결과**: 1,350여 라인에 달하는 복합 K8s 리소스 YAML이 에러 없이 깔끔히 파싱되고 렌더링에 통과했습니다.
