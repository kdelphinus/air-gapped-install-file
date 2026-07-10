# Tekton v1.9.0 LTS

Kubernetes-native CI/CD 프레임워크.
공식 Helm 차트가 없으므로, 공식 release YAML 매니페스트를 에어갭 환경에 맞춰 동적 치환하여 설치합니다.

---

## 📌 구성 명세

| 항목 | 값 |
| :--- | :--- |
| Tekton Pipelines | v1.9.0 LTS (EOL: 2027-01-30) |
| Tekton Triggers | v0.34.0 (선택) |
| Tekton Dashboard | v0.65.0 (선택) |
| Namespace | tekton-pipelines |
| Dashboard NodePort | 30004 (Dashboard 설치 시) |

---

## 📂 디렉토리 구조

```text
tekton-1.9.0/
├── manifests/
│   ├── pipelines-v1.9.0-release.yaml    # 필수 (사전 다운로드)
│   ├── triggers-v0.34.0-release.yaml    # 선택
│   └── dashboard-v0.65.0-release.yaml   # 선택
├── images/
│   └── upload_images_to_harbor_v3-lite.sh
└── scripts/
    ├── download_assets_offline.sh       # 에셋 동적 파싱 및 다운로드
    ├── install.sh                       # 대화형 멱등 설치
    └── uninstall.sh                     # 멱등 제거 및 초기화
```

---

## 🛠️ 주요 설정 및 특이사항

### 1. 매니페스트 기반 이미지 동적 수집
Tekton 릴리즈 매니페스트는 빌드 SHA 해시가 결합된 이미지 주소(`controller-10a3e327...:v1.9.0` 등)를 참조합니다.
`download_assets_offline.sh` 는 매니페스트 전체를 파싱하여 실존하는 이미지 경로를 동적으로 추출·수집하므로 수동 리스트 구성 시 일어나는 누락을 방지합니다.

### 2. 다중 레지스트리 대응 rewrite 체계
`install.sh` 는 매니페스트 내 이미지 경로를 `sed` 정규식으로 Harbor 주소로 교체합니다.
`ghcr.io/tektoncd` 와 `gcr.io/tekton-releases` 레지스트리 양쪽 모두의 주소를 파싱하여 로컬 Harbor 경로로의 다중 맵 치환을 수행하며, `@sha256:` digest 지정을 제거합니다.

### 3. 멱등 라이프사이클 관리
인프라 가변 정보는 `install.conf` 에 보존되어 업그레이드 시 기존 입력 정보를 멱등하게 유지하며, 일반 언인스톨과 `--reset` 초기화 수명주기를 완벽히 분리하였습니다.

---

## 🚀 시작하기

상세한 설치 및 차단 테스트 방법은 **[install-guide.md](./install-guide.md)**를 참조하세요.

1. **에셋 준비:** `./scripts/download_assets_offline.sh` (외부망)
2. **이미지 업로드:** `./images/upload_images_to_harbor_v3-lite.sh` (폐쇄망)
3. **설치 실행:** `./scripts/install.sh` (폐쇄망)
