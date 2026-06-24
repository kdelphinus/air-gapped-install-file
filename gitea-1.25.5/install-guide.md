# Gitea v1.25.5 오프라인 설치 가이드

폐쇄망 환경에서 Gitea Git 서버를 Kubernetes 위에 설치하는 절차를 안내합니다.

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 스크립트 디렉토리로 이동
cd scripts/

# 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.



## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- Envoy Gateway 설치 완료 (도메인 접속 사용 시)

## 아키텍처 개요

```text
Client → NodePort :30003 → Gitea Pod (HTTP/Web UI)
Client → NodePort :30022 → Gitea Pod (SSH/Git)
Client → Envoy Gateway → gitea.devops.internal (도메인, 선택)
```

## 1단계: Helm 차트 준비

인터넷이 되는 환경에서 차트를 다운로드합니다.

```bash
helm repo add gitea-charts https://dl.gitea.com/charts/
helm pull gitea-charts/gitea --version 12.5.3 --untar --untardir ./charts/
```

## 2단계: 이미지 Harbor 업로드

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 3단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 선택 항목:

1. **이미지 소스**: `1` (Harbor) 또는 `2` (로컬 tar)
2. **데이터베이스**: `1` (SQLite, 기본) 또는 `2` (PostgreSQL)
3. **노드 고정**: Gitea 를 배치할 특정 워커 노드 이름 (엔터 = 자동)

## 4단계: 초기 접속

### 관리자 계정

초기 관리자 계정은 `values.yaml` 의 `adminUser` 항목을 참조하세요.
설치 후 첫 접속 시 관리자 비밀번호를 설정합니다.

```bash
# 관리자 비밀번호 확인 (Secret 방식인 경우)
kubectl get secret gitea-admin-secret -n gitea \
  -o jsonpath='{.data.password}' | base64 -d
```

### 접속 주소

| 접속 방식 | 주소 |
| :--- | :--- |
| NodePort (HTTP) | `http://<NODE_IP>:30003` |
| NodePort (SSH) | `ssh://git@<NODE_IP>:30022` |
| 도메인 | `http://gitea.devops.internal` |

### Git 클라이언트 설정

```bash
# HTTP 방식
git clone http://<NODE_IP>:30003/<USER>/<REPO>.git

# SSH 방식
git clone ssh://git@<NODE_IP>:30022/<USER>/<REPO>.git
```

## 5단계: TLS 적용 (HTTPS, 선택)

Envoy Gateway 에서 TLS Termination 을 처리합니다.

```bash
kubectl create secret tls gitea-tls \
  --cert=cert.pem \
  --key=key.pem \
  --namespace gitea
```

`manifests/httproute-gitea.yaml` 에 HTTPS 리스너 참조를 추가하세요.

## 운영 — 로그 확인

```bash
# Gitea Pod 로그
kubectl logs -n gitea -f -l app.kubernetes.io/name=gitea

# 전체 Pod 상태
kubectl get pods -n gitea
kubectl get svc -n gitea
```

## SQLite → PostgreSQL 전환 (업그레이드)

1. Gitea 관리자 페이지 → 사이트 관리 → 데이터베이스 마이그레이션 실행
2. `install.sh` 재실행 시 DB 타입 `2` (PostgreSQL) 선택
3. 기존 데이터는 마이그레이션 후 SQLite 파일 삭제

## 삭제

```bash
./scripts/uninstall.sh
```

삭제 시 PV/PVC 삭제 여부를 선택합니다. PV 는 `Retain` 정책이므로 PVC 삭제 후에도 호스트 데이터는 유지됩니다.
