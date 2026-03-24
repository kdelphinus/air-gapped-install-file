# 🚀 Harbor v1.14.3 오프라인 설치 가이드

폐쇄망 환경에서 Harbor v1.14.3을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료 (master + worker)
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 설치용 이미지 `.tar` 파일 준비 완료

## 설치 전 필수 확인 사항

- **TLS 없이 IP로만 접속 시**: `EXTERNAL_HOSTNAME` 을 Harbor NodePort IP와 동일하게 설정
- **TLS 도메인 접속 시**: 사전에 인증서로 Kubernetes Secret 생성 필요, `EXTERNAL_HOSTNAME` 을 도메인명으로 설정
- **저장 경로**: `SAVE_PATH` (데이터 저장 경로)는 `NODE_NAME` 노드에서 디렉토리가 생성되어 있어야 함 (권한: `chmod 777`)

## 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

이미지 로드 확인:

```bash
sudo ctr -n k8s.io images list | grep harbor
```

## 2단계: 설치 스크립트 설정

`scripts/install.sh` 상단 Config 블록을 환경에 맞게 수정합니다.

| 변수 | 설명 | 예시 |
| :--- | :--- | :--- |
| `HARBOR_NAMESPACE` | Harbor 설치 네임스페이스 | `harbor` |
| `HARBOR_RELEASE_NAME` | Helm release 이름 | `harbor` |
| `HELM_CHART_PATH` | Helm 차트 파일 경로 | `./charts/harbor-1.14.3.tgz` |
| `EXTERNAL_HOSTNAME` | Harbor 접근 호스트명 또는 IP | `<NODE_IP>` 또는 도메인 |
| `SAVE_PATH` | PV 데이터 저장 경로 (호스트) | `/harbor/data` |
| `NODE_NAME` | PV가 위치할 노드 이름 | `worker-node-01` |
| `STORAGE_SIZE` | PVC 요청 크기 | `40Gi` |

## 3단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 아래 항목을 인터랙티브하게 입력합니다.

- TLS 활성화 여부 (y/N)
- TLS 사용 시 사전 생성된 Secret 이름
- Harbor 관리자(`admin`) 비밀번호

## 4단계: (TLS 미사용 시) Insecure Registry 등록

TLS를 사용하지 않는 경우, 모든 노드에서 containerd에 insecure registry를 등록합니다.

```bash
chmod +x scripts/insecurity_registry_add.sh
./scripts/insecurity_registry_add.sh
```

## 5단계: (선택) Self-Signed TLS 인증서 생성

도메인 접속 시 자체 서명 인증서가 필요한 경우 생성합니다.

```bash
chmod +x scripts/create_self-signed_tls.sh
./scripts/create_self-signed_tls.sh
```

## 6단계: 설치 확인 및 접속

```bash
kubectl get pods -n harbor
kubectl get svc -n harbor
```

### 접속 정보

| 방법 | 주소 |
| :--- | :--- |
| **NodePort (HTTP)** | `http://<NODE_IP>:30002` |
| **Ingress (TLS)** | `https://<EXTERNAL_HOSTNAME>` |

- 기본 계정: `admin` / 설치 시 입력한 비밀번호

## 이미지 Push 예시

```bash
docker login <NODE_IP>:30002 -u admin
docker tag my-image:v1 <NODE_IP>:30002/library/my-image:v1
docker push <NODE_IP>:30002/library/my-image:v1
```

## 삭제

```bash
./scripts/uninstall.sh
```
