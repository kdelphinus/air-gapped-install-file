# Tekton v1.9.0 LTS 오프라인 설치 가이드

폐쇄망 환경에서 Tekton을 Kubernetes 위에 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- `kubectl` CLI 사용 가능

## 컴포넌트 구성

| 컴포넌트 | 역할 | 필수 여부 |
| :--- | :--- | :--- |
| **Pipelines** | Pipeline, Task, PipelineRun 등 핵심 CRD 및 컨트롤러 | ✅ 필수 |
| **Triggers** | Git 이벤트(Webhook) 기반 자동 파이프라인 실행 | 선택 |
| **Dashboard** | 파이프라인 실행 현황 웹 UI | 선택 |

## 1단계: 매니페스트 및 이미지 준비 (인터넷 환경)

```bash
# 매니페스트 다운로드
curl -L https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.9.0/release.yaml \
  -o manifests/pipelines-v1.9.0-release.yaml

# 이미지 목록 추출
grep 'image:' manifests/pipelines-v1.9.0-release.yaml | \
  awk '{print $2}' | sort -u > /tmp/tekton-images.txt

cat /tmp/tekton-images.txt

# 이미지 저장 (docker 환경)
while read -r img; do
  docker pull "$img"
done < /tmp/tekton-images.txt

docker save $(cat /tmp/tekton-images.txt | tr '\n' ' ') \
  -o images/tekton-pipelines.tar
```

Triggers, Dashboard 도 동일한 방법으로 이미지를 준비합니다.

## 2단계: 이미지 Harbor 업로드

```bash
chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

> `upload_images_to_harbor_v3-lite.sh` 는 tar 파일 내 이미지명의 **마지막 세그먼트**만
> Harbor 경로로 사용합니다.
> 예: `ghcr.io/tektoncd/pipeline/cmd/controller:v1.9.0` → `<HARBOR>/library/controller:v1.9.0`

## 3단계: 이미지 경로 패턴 확인

폐쇄망 설치 전 release.yaml 의 이미지 레지스트리를 반드시 확인합니다.

```bash
grep 'image:' manifests/pipelines-v1.9.0-release.yaml | sort -u
```

예상 패턴 (v1.9.0 기준):

```text
ghcr.io/tektoncd/pipeline/cmd/controller:v1.9.0
ghcr.io/tektoncd/pipeline/cmd/webhook:v1.9.0
ghcr.io/tektoncd/pipeline/cmd/entrypoint:v1.9.0
...
```

`gcr.io/tekton-releases` 패턴이면 `scripts/install.sh` 의 `rewrite_manifest()` 함수 내
sed 패턴이 이미 두 레지스트리 모두 처리합니다.

## 4단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 선택 항목:

1. **이미지 소스**: `1` (Harbor) 또는 `2` (로컬 tar)
2. **Triggers 설치 여부**: `y/n`
3. **Dashboard 설치 여부**: `y/n`

## 5단계: 설치 확인

```bash
# 전체 Pod 상태
kubectl get pods -n tekton-pipelines

# Tekton CLI 버전 확인
tkn version

# CRD 등록 확인
kubectl get crd | grep tekton
```

## 6단계: 첫 Pipeline 테스트

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

## Dashboard 접속

Dashboard 설치 시 NodePort 30004 로 접속합니다.

```text
http://<NODE_IP>:30004
```

## 운영 — 로그 확인

```bash
# Pipelines 컨트롤러 로그
kubectl logs -n tekton-pipelines -f \
  -l app=tekton-pipelines-controller

# 특정 PipelineRun 로그
tkn pipelinerun logs <PIPELINERUN_NAME> -f
```

## 삭제

```bash
./scripts/uninstall.sh
```
