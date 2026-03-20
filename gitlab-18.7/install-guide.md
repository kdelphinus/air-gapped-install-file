# 🚀 GitLab v18.7 오프라인 설치 가이드

폐쇄망 환경에서 GitLab EE v18.7을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- (도메인 접속 사용 시) Envoy Gateway 또는 Ingress-Nginx 설치 완료

## 1단계: 호스트 디렉토리 생성

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다. PV 데이터 저장 경로를 대상 노드에 미리 생성합니다.

```bash
chmod +x scripts/setup-host-dirs.sh
./scripts/setup-host-dirs.sh
```

## 2단계: 이미지 Harbor 업로드

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 3단계: 운영 설정 (values.yaml 및 PV)

루트 디렉토리의 설정 파일들을 환경에 맞게 수정합니다.

| 파일명 | 용도 | 주요 수정 항목 |
| :--- | :--- | :--- |
| **`values.yaml`** | GitLab 운영 설정 | 도메인, 이미지 경로, 리소스 제한 등 |
| **`manifests/gitlab-pv.yaml`** | 영구 저장소(PV) 정의 | 노드 이름(`nodeAffinity`), 저장 경로 |
| **`manifests/gitlab-httproutes.yaml`** | Envoy용 라우팅 설정 | 도메인 이름, 게이트웨이 참조 |

## 4단계: 설치 실행

```bash
chmod +x scripts/install-gitlab.sh
./scripts/install-gitlab.sh
```

스크립트 실행 중 다음 항목을 선택/입력합니다:
1. **Ingress 방식**: `1` (NGINX Ingress) 또는 `2` (Envoy Gateway)
2. **대상 노드**: GitLab을 배치할 특정 노드 이름 (선택)

스크립트 자동 처리 항목:
- 네임스페이스 및 PV/PVC 생성
- Helm 배포 (Harbor 이미지 경로 자동 생성)
- HTTPRoute 적용 (Envoy 선택 시)
- CoreDNS 도메인 자동 등록

## 5단계: 설치 확인

```bash
# 파드 및 서비스 상태 확인
kubectl get pods,svc -n gitlab

# 마이그레이션 Job 성공 여부 확인
kubectl get jobs -n gitlab
```

## 6단계: 초기 접속

초기 `root` 비밀번호 확인:

```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath="{.data.password}" | base64 -d && echo
```

| 항목 | 값 |
| :--- | :--- |
| **접속 주소** | `http://<NODE_IP>` 또는 설정한 도메인 |
| **관리자 계정** | `root` |
| **비밀번호** | 위 명령으로 확인한 값 |

> **보안 권고**: 최초 로그인 후 비밀번호를 즉시 변경하십시오.
