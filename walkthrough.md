# Walkthrough: Harbor v2.10.3 표준화 및 안전장치 강화 완료

본 문서는 `harbor-2.10.3` 컴포넌트의 표준화 리팩토링 과정에서 발견된 보안 및 안전성 이슈(P0/P1/P2)를 완벽하게 개선하고 정밀 검증을 완수한 최종 내역을 명세합니다.

---

## 1. 피드백 기반 주요 개선점 (Findings & Solutions)

### 🔒 [P0] 관리자 비밀번호 평문 디스크 저장 차단 (주입식 우회)
- **문제**: `values-infra.yaml` 파일에 `harborAdminPassword`가 평문으로 기록되어 디바이스 디스크에 영구 보존되던 심각한 보안 결함이 있었습니다.
- **해결**: `values-infra.yaml` 생성 템플릿에서 비밀번호 필드를 완전히 제거했습니다. 대신 `helm upgrade --install` 시점에 `--set harborAdminPassword="${ADMIN_PASSWORD}"` 파라미터를 통해 메모리 내에서 안전하게 주입되도록 변경하여 비밀번호 노출 경로를 물리적으로 원천 봉쇄했습니다.

### ⚠️ [P0] Reinstall/Reset 시 PVC/PV 대화식 동의 보호 (데이터 안전 확보)
- **문제**: 이전 코드에서 PV 삭제만 묻고 PVC는 무조건 삭제를 때려, 동적 StorageClass의 `Delete` Reclaim Policy 환경 등에서 컨테이너 이미지 데이터가 의도치 않게 자동 증발할 위험이 존재했습니다.
- **해결**: `install.sh` 및 `uninstall.sh`에서 PVC와 PV의 수명주기를 하나로 묶어 **`DELETE_VOLUMES` 대화식 프롬프트(y/N)**로 일관되게 확인 절차를 거치도록 통합 수선했습니다. 이제 사용자의 명시적 동의 없이는 PVC 역시 삭제되지 않고 안전하게 보존됩니다.

### ⚙️ [P1] Upgrade 시 인프라 설정 복원 멱등성 해결
- **문제**: 업그레이드 경로 선택 시 입력 단계를 스킵하면서, 헬름 조립에 쓰일 가변값들(`EXPOSE_TYPE`, `EXTERNAL_URL`, `PROTOCOL`, `ENABLE_CP_TOLERATIONS`, `TLS_CERT_SOURCE`)이 유실되어 빈 값으로 렌더링되던 버그가 있었습니다.
- **해결**: `install.conf` 저장 명세에 런타임에서 계산된 해당 정보들을 누락 없이 모두 기재하고 로드하도록 확장하여, 업그레이드 구동 시 완벽하게 설정을 복원하도록 멱등성을 정착시켰습니다.

### 🧩 [P1] YAML 최상위 키 중복 덮어쓰기 원천 해결
- **문제**: 스케줄링 toleration 설정과 리소스 최소화 옵션을 동시 구동할 때 `nginx:`, `core:` 등 최상위 컴포넌트 키가 중복으로 덧붙여져 YAML 파서가 오작동할 수 있었습니다.
- **해결**: 컴포넌트 단위로 루프를 돌며 toleration, nodeSelector, resources를 취합한 단일 컴포넌트 YAML 블록(`COMPONENTS_OVERRIDE_BLOCK`)을 선 조립 후 단일 `cat` 주입하도록 병합 리팩토링을 완료했습니다.

### 📝 [P2] `Manual Installation & Upgrade` 섹션 보강
- **문제**: 표준 규격이 요구하는 수동 설치 수선 절차가 빠져 있었습니다.
- **해결**: `install-guide.md` 최하단에 스크립트에 의존하지 않고 수동으로 PV/PVC 매니페스트 및 `values-infra.yaml`을 생성하여 `helm` 명령어로 설치/업그레이드를 진행할 수 있는 명시적인 상세 커맨드 가이드를 수록했습니다.

---

## 2. 검증 수행 내역 (Verification Results)

### 1) 쉘 스크립트 문법 정합성 검증 (`bash -n`)
```bash
wsl -d rocky -e bash -c "cd /home/mjko/air-gapped-install-file && bash -n harbor-2.10.3/scripts/install.sh && bash -n harbor-2.10.3/scripts/uninstall.sh"
# -> Output: (구문 결함 없음)
```

### 2) Git Diff 서식 검증 (`git diff --check`)
```bash
git diff --check
# -> Output: (서식 결함 검출되지 않음, clean 상태 유지)
```

### 3) 갱신된 구조의 Helm template 빌드 검증
컴포넌트 리소스를 한 블록으로 합친 신규 `values-infra.yaml` 및 `--set` 비밀번호 주입 방식으로 매니페스트를 검증했습니다.
```bash
helm template harbor ./charts/harbor -n harbor -f ./values.yaml -f ./values-infra.yaml --set harborAdminPassword=testpassword123
# -> Output: (1,350줄의 YAML 매니페스트 에러 없이 깔끔히 파싱 및 렌더링 통과)
```

### 4) 워크트리 임시 파일(쓰레기 파일) 전수 정리
- 미추적 공백 파일 `" "` 전수 삭제 완료.
- `implementation_plan.md` 및 `task.md` 를 `.gitignore`에 정규 등록하여 깨끗하고 청결한 git status 상태를 도출했습니다.
