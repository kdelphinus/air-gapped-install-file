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

## 1단계: 구성 이미지 로드 (ctr import)

하버가 설치되기 전이므로, 하버 구성 이미지들을 **모든 Kubernetes 노드(Master, Worker)**에서 직접 로컬 `containerd`에 로드해야 합니다.

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
chmod +x scripts/load_images.sh
sudo ./scripts/load_images.sh
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
| `HELM_CHART_PATH` | Helm 차트 경로 | `./charts/harbor` |
| `EXTERNAL_HOSTNAME` | Harbor 접근 호스트명 또는 IP | `<NODE_IP>` 또는 도메인 |
| `SAVE_PATH` | PV 데이터 저장 경로 (호스트) | `/harbor/data` |
| `NODE_NAME` | PV가 위치할 노드 이름 | `worker-node-01` |
| `STORAGE_SIZE` | PVC 요청 크기 | `40Gi` |

## 3단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 아래 항목을 인터랙티브하게 선택/입력합니다.

1. **이미지 로드 방식 선택**:
   - **`1` 로컬 tar 직접 import (권장)**: 하버가 아직 설치되지 않은 경우 선택합니다. (1단계에서 `load_images.sh`를 이미 실행했다면 이미 로드되어 있으므로 금방 넘어갑니다.)
   - **`2` Harbor 레지스트리 사용**: 하버가 이미 설치되어 있고 재설치하거나 이미지가 이미 로드된 경우 선택합니다.
2. **노출 방식 선택**: `1` NodePort + Envoy Gateway (기본) / `2` nginx Ingress
3. **Harbor 관리자(`admin`) 비밀번호**: 최소 8자 이상의 비밀번호를 입력합니다.

## 4단계: Envoy HTTPRoute 적용 (NodePort + Envoy 선택 시)

`manifests/route-harbor.yaml`의 `hostnames`와 `parentRefs.name`을
실제 환경에 맞게 수정 후 적용합니다.

```bash
# hostnames: 를 실제 도메인으로 수정 후:
kubectl apply -f manifests/route-harbor.yaml
```

## 4단계: (TLS 미사용 시) Insecure Registry 등록

HTTP로 Harbor를 사용하는 경우, 모든 노드에서 containerd에 등록합니다.

```bash
chmod +x scripts/insecurity_registry_add.sh
./scripts/insecurity_registry_add.sh
```

## 5단계: (선택) Self-Signed TLS 인증서 생성

nginx Ingress + TLS 사용 시 자체 서명 인증서가 필요한 경우 생성합니다.

```bash
chmod +x scripts/create_self-signed_tls.sh
./scripts/create_self-signed_tls.sh
```

## 7단계: (선택) Trivy 취약점 DB 수동 반입

에어갭 환경에서는 Trivy가 인터넷을 통해 취약점 DB를 업데이트할 수 없습니다. 보안 스캔 기능을 사용하려면 수동으로 DB를 반입해야 합니다.

1.  **외부망**에서 아래 두 파일을 다운로드합니다.
    *   [Vulnerability DB](https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-offline-db.tgz) (파일명: `trivy-db.tar.gz`로 저장)
    *   [Java DB](https://github.com/aquasecurity/trivy-java-db/releases/latest/download/javadb.tar.gz) (파일명: `trivy-java-db.tar.gz`로 저장)
2.  다운로드한 두 파일을 Harbor 컴포넌트 루트(`harbor-1.14.3/`) 폴더에 넣습니다.
3.  반입 스크립트를 실행합니다.
    ```bash
    chmod +x scripts/import_trivy_db.sh
    ./scripts/import_trivy_db.sh
    ```

반입이 완료되면 Harbor UI에서 이미지를 선택하고 **[Scan]** 버튼을 눌러 보안 검사를 수행할 수 있습니다.

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

## 보안 고려사항

- **비밀번호 정책**: 관리자 비밀번호는 최소 8자 이상 설정 (install.sh에서 검증)
- **TLS 권장**: 운영 환경에서는 외부 TLS + 내부 TLS 모두 활성화 권장
  (`internalTLS.enabled: true`)
- **자격 증명 관리**: 스크립트에 비밀번호를 직접 기재하지 않고,
  환경변수 또는 실행 시 프롬프트 사용
- **Insecure Registry**: TLS 미사용 시
  `insecurity_registry_add.sh`로 등록하되,
  신뢰할 수 있는 네트워크에서만 사용
- **Trivy 스캔**: 폐쇄망에서는 Trivy DB를 OCI artifact로
  반입 후 활성화 가능 (`values.yaml` 주석 참조)

## 트러블슈팅

- **Pod CrashLoopBackOff**: PV 마운트 경로 권한(`chmod 777`) 확인, 비밀번호 불일치 여부 점검
- **이미지 Push 실패**: 모든 노드에서 insecure registry 등록 여부 확인 (`scripts/insecurity_registry_add.sh`)
- **TLS 인증서 오류**: Secret 이름과 `EXTERNAL_HOSTNAME` 도메인 일치 여부, 인증서 만료일 확인
- **PVC Pending**: `NODE_NAME`이 실제 노드 이름과 일치하는지, nodeAffinity 설정 확인
