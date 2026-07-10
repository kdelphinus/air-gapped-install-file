# 🚀 Tekton 폐쇄망 설치 가이드 (v1.9.0 LTS)

Kubernetes-native CI/CD 프레임워크인 Tekton을 폐쇄망 환경에 설치하고 첫 파이프라인을 구동하는 절차입니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 YAML 매니페스트와 컨테이너 이미지(.tar)가 `manifests/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 스크립트 실행 권한 부여 및 자산 다운로드
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `manifests/` 디렉토리에 3대 구성 릴리즈 YAML 파일이, `images/` 디렉토리에 릴리즈 매니페스트와 100% 동기화된 컨테이너 이미지 `.tar` 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

> **에어갭 완결성 보완**: `download_assets_offline.sh`는 매니페스트 파일들(`pipelines`, `triggers`, `dashboard` YAML)에 정의된 실존하는 `ghcr.io/tektoncd` 및 `gcr.io/tekton-releases` 이미지 목록을 **동적으로 파싱하여 수집**하므로, 실제 구동 시 해시 불일치로 인한 `ErrImagePull` 장애를 원천 예방합니다.

---

## 1. 전제 조건

- Kubernetes 클러스터 구성 완료
- 로컬 Harbor 레지스트리 접근 가능 (`<HARBOR_REGISTRY>`)
- `kubectl` CLI 사용 가능

---

## 2. 1단계: 이미지 Harbor 업로드 (폐쇄망 환경)

모든 작업은 컴포넌트 루트 디렉토리(`tekton-1.9.0/`)에서 실행합니다.

```bash
# 1. 수집된 모든 이미지 로컬 containerd(k8s.io)에 import
for f in images/*.tar; do sudo ctr -n k8s.io images import "$f"; done

# 2. 이미지 마이그레이션 및 Harbor 푸시 실행
chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

> **태깅 규칙 주의**: `upload_images_to_harbor_v3-lite.sh` 는 tar 파일 내 이미지명의 **마지막 세그먼트**만 Harbor 경로로 사용합니다.
> 예: `ghcr.io/tektoncd/pipeline/controller-10a3e32792f33651396d02b6855a6e36:v1.9.0`
> → `<HARBOR>/library/controller-10a3e32792f33651396d02b6855a6e36:v1.9.0`
>
> **Windows 노드 미지원 안내**: 원본 매니페스트 내 Windows 전용 파워셸 이미지(`mcr.microsoft.com/powershell`)도 수집 및 치환 범위에는 포함되어 있으나, 본 가이드는 리눅스 노드 전용이므로 해당 윈도우 파드 기동은 고려 대상에서 제외됩니다.

---

## 3. 2단계: 설치 실행 (대화형)

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# 헬름 설치가 아닌, 공식 매니페스트 동적 치환 설치 기동
chmod +x scripts/install.sh
./scripts/install.sh
```

### 주요 입력 정보 및 처리 방식
* **이미지 소스**:
  * `1` (Harbor) 또는 `2` (로컬 tar 직접 import)
* **설정 동기화**:
  * 입력된 설정은 가변 인프라 설정 전용 파일인 `install.conf` 에 저장되어 재설치 및 업그레이드 시 멱등 배포를 보장하며, 오직 `--reset` 초기화 명령 시에만 소거됩니다.
* **표준 수명주기**:
  * 기존 설치나 `install.conf` 감지 시 표준 메뉴(`1) Upgrade`, `2) Reinstall`, `3) Reset`, `4) Cancel`) 분기를 제공합니다.

---

## 4. 3단계: 설치 확인

```bash
# 전체 Pod 상태
kubectl get pods -n tekton-pipelines

# Tekton CLI 버전 확인
tkn version

# CRD 등록 확인
kubectl get crd | grep tekton
```

---

## 5. 4단계: 첫 Pipeline 테스트

```bash
# 간단한 Hello World Pipeline 실행
kubectl apply -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: hello
spec:
  steps:
    - name: echo
      image: <NODE_IP>:30002/library/alpine:latest
      script: |
        echo "Hello from Tekton!"
EOF

kubectl apply -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  generateName: hello-run-
spec:
  taskRef:
    name: hello
EOF

# 실행 결과 확인
tkn taskrun logs --last
```

---

## 6. Dashboard 접속

Dashboard 설치 시 NodePort 30004 로 접속합니다.
```text
http://<NODE_IP>:30004
```

---

## 7. 수동 설치 및 업그레이드 가이드 (Manual Installation & Upgrade)

자동화 스크립트 장애 대처용 수동 반영 가이드라인입니다.

### 7.1. 수동 설치 진행
1. 설치 대상 파일(`pipelines-v1.9.0-release.yaml` 등) 내 이미지 주소를 로컬 Harbor 주소에 맞춰 수동 치환(rewrite)합니다.
   * **치환 규칙**: `ghcr.io/tektoncd/[component]/[image-name]:[tag][@sha256:digest]` 에서 `ghcr.io/tektoncd/[component]/` 부분을 `${HARBOR_REGISTRY}/${HARBOR_PROJECT}/` 로 치환하고, `@sha256:...` 부분은 삭제합니다.
   ```bash
   # 예시: Pipelines 수동 이미지 치환 (복수 레지스트리 대응 정규식)
   sed -E \
     -e "s|(ghcr\.io/tektoncd\|gcr\.io/tekton-releases)/[^/]+/\([^:\"' ]*\):\([^@\"' ]*\)@sha256:[a-zA-Z0-9:]*|192.168.1.10:30002/library/\2:\3|g" \
     -e "s|(ghcr\.io/tektoncd\|gcr\.io/tekton-releases)/[^/]+/\([^:\"' ]*\):\([^@\"' ]*\)|192.168.1.10:30002/library/\2:\3|g" \
     manifests/pipelines-v1.9.0-release.yaml > /tmp/pipelines-manual.yaml
   ```
2. 치환된 임시 매니페스트를 적용합니다.
   ```bash
   kubectl apply -f /tmp/pipelines-manual.yaml
   ```

---

## 8. 서비스 삭제 및 초기화

Tekton 스택을 완전히 제거하려면 다음 명령을 사용합니다.

```bash
# 리소스 삭제 (설정 파일 보존)
sudo ./scripts/uninstall.sh

# 완전 초기화 (설정 파일 완전 제거)
sudo ./scripts/uninstall.sh --reset
```
