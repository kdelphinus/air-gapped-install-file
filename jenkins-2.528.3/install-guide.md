# Jenkins v2.528.3 오프라인 설치 가이드

폐쇄망 환경에서 Jenkins v2.528.3을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- Harbor에 Jenkins 이미지 사전 업로드 완료

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `jenkins/` | Jenkins Helm 차트 |
| `images/` | Jenkins 컨테이너 이미지 `.tar` 파일 |
| `deploy-jenkins.sh` | 설치 자동화 스크립트 |
| `pv-volume.yaml` | Jenkins 홈 PV 정의 (20Gi) |
| `gradle-cache-pv-pvc.yaml` | Gradle 캐시 PV/PVC 정의 (5Gi) |
| `route-jenkins.yaml` | HTTPRoute 정의 (Envoy Gateway 사용 시) |
| `setup-host-dirs.sh` | 호스트 디렉토리 사전 생성 스크립트 |

## Phase 1: 호스트 디렉토리 생성

PV 데이터 저장 경로를 대상 노드에 미리 생성합니다.

```bash
chmod +x setup-host-dirs.sh
./setup-host-dirs.sh
```

## Phase 2: PV 파일 설정

`pv-volume.yaml` 에서 아래 항목을 환경에 맞게 수정합니다.

| 항목 | 설명 | 기본값 |
| :--- | :--- | :--- |
| `hostPath.path` | Jenkins 홈 데이터 저장 경로 | `/var/jenkins_home` |
| `nodeAffinity` 노드명 | PV가 위치할 워커 노드 이름 | - |
| `storage` 용량 | Jenkins 홈 용량 | `20Gi` |

`gradle-cache-pv-pvc.yaml` 에서 Gradle 캐시 경로도 수정합니다.

```yaml
hostPath:
  path: /data/gradle-cache
```

## Phase 3: deploy-jenkins.sh 설정

`deploy-jenkins.sh` 상단 Config 블록을 환경에 맞게 수정합니다.

| 변수 | 설명 | 기본값 |
| :--- | :--- | :--- |
| `REGISTRY_URL` | Harbor 레지스트리 주소 | `<NODE_IP>:30002` |
| `CONTROLLER_REPO` | Jenkins Controller 이미지 경로 | `library/cmp-jenkins-full` |
| `CONTROLLER_TAG` | Jenkins Controller 이미지 태그 | `2.528.3` |
| `AGENT_REPO` | Jenkins Agent 이미지 경로 | `library/inbound-agent` |
| `SIDECAR_REPO` | Config Auto Reload 사이드카 이미지 | `library/k8s-sidecar` |
| `NAMESPACE` | Jenkins 설치 네임스페이스 | `jenkins` |
| `STORAGE_SIZE` | Jenkins 홈 PVC 크기 | `20Gi` |
| `NODE_PORT` | Jenkins 웹 NodePort | `30000` |

## Phase 4: Harbor ImagePullSecret 생성

Harbor 이미지를 pull하기 위한 Secret을 생성합니다.

```bash
kubectl create namespace jenkins

kubectl create secret docker-registry regcred \
  --docker-server=<NODE_IP>:30002 \
  --docker-username=admin \
  --docker-password=<HARBOR_PASSWORD> \
  -n jenkins
```

## Phase 5: 설치 실행

```bash
chmod +x deploy-jenkins.sh
./deploy-jenkins.sh
```

스크립트 실행 중 배포할 노드 이름을 입력합니다.

스크립트가 자동으로 처리하는 항목:

- Namespace 생성 확인
- PV/PVC 적용 (Jenkins 홈 + Gradle 캐시)
- 노드 라벨 적용 (`jenkins-node=true`)
- Helm 배포 (신규 install 또는 기존 upgrade)
- Pod Ready 대기 (최대 5분)
- 초기 관리자 비밀번호 출력

## Phase 6: 설치 확인

```bash
kubectl get pods -n jenkins
kubectl get pv | grep jenkins
kubectl get svc -n jenkins
```

## Phase 7: 초기 접속

| 항목 | 값 |
| :--- | :--- |
| 접속 주소 | `http://<NODE_IP>:30000` |
| 계정 | `admin` |
| 비밀번호 | 스크립트 출력에서 확인 |

비밀번호 수동 확인:

```bash
kubectl get secret jenkins -n jenkins \
  -o jsonpath="{.data.jenkins-admin-password}" | base64 -d && echo
```

## 참고: 마이그레이션 가이드

Jenkins 인스턴스 이전(Export/Import) 절차는 `export_import/guide.md` 를 참조하세요.
