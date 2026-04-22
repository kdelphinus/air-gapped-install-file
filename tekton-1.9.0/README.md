# Tekton v1.9.0 LTS

Kubernetes-native CI/CD 프레임워크.
공식 Helm 차트 없음 — 공식 release YAML 매니페스트 기반으로 설치.

## 구성 명세

| 항목 | 값 |
| :--- | :--- |
| Tekton Pipelines | v1.9.0 LTS (EOL: 2027-01-30) |
| Tekton Triggers | v0.34.x (선택) |
| Tekton Dashboard | v0.65.0 (선택) |
| Namespace | tekton-pipelines |
| Dashboard NodePort | 30004 (Dashboard 설치 시) |

## 이미지 목록

| 이미지 | 태그 | 파일명 | 필수 |
| :--- | :--- | :--- | :--- |
| Pipelines 이미지 묶음 | v1.9.0 | `tekton-pipelines.tar` | ✅ |
| Triggers 이미지 묶음 | v0.34.x | `tekton-triggers.tar` | 선택 |
| Dashboard 이미지 | v0.65.0 | `tekton-dashboard.tar` | 선택 |

> 이미지는 release.yaml 에서 `grep 'image:'` 로 추출 후 `docker pull && docker save` 로 준비.

## 디렉토리 구조

```text
tekton-1.9.0/
├── manifests/
│   ├── pipelines-v1.9.0-release.yaml    # 필수 (사전 다운로드)
│   ├── triggers-v0.34.x-release.yaml    # 선택
│   └── dashboard-v0.65.0-release.yaml   # 선택
├── images/
│   ├── tekton-pipelines.tar
│   ├── tekton-triggers.tar              # 선택
│   ├── tekton-dashboard.tar             # 선택
│   └── upload_images_to_harbor_v3-lite.sh
└── scripts/
    ├── install.sh
    └── uninstall.sh
```

## 사전 준비 (인터넷 환경)

```bash
# 매니페스트 다운로드
curl -L https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.9.0/release.yaml \
  -o manifests/pipelines-v1.9.0-release.yaml

# 선택 컴포넌트
curl -L https://storage.googleapis.com/tekton-releases/triggers/previous/v0.34.0/release.yaml \
  -o manifests/triggers-v0.34.x-release.yaml

curl -L https://storage.googleapis.com/tekton-releases/dashboard/previous/v0.65.0/release.yaml \
  -o manifests/dashboard-v0.65.0-release.yaml
```

## 빠른 시작

```bash
# 1. 이미지 Harbor 업로드
./images/upload_images_to_harbor_v3-lite.sh

# 2. 설치
chmod +x scripts/install.sh
./scripts/install.sh
```

자세한 내용은 `install-guide.md` 참조.

## 이미지 경로 rewrite 주의사항

`install.sh` 는 release.yaml 내 이미지 경로를 `sed` 로 Harbor 주소로 교체합니다.
Tekton v1.9.0 이미지 레지스트리는 `ghcr.io/tektoncd` 기준으로 작성되어 있습니다.
`gcr.io/tekton-releases` 를 사용하는 경우 `install.sh` 의 sed 패턴을 수정하세요.

실제 이미지 경로 확인 방법:

```bash
grep 'image:' manifests/pipelines-v1.9.0-release.yaml | sort -u
```
