# 🚀 ArgoCD v2.12.1 오프라인 설치 가이드

본 문서는 오프라인(폐쇄망) 환경에서 ArgoCD를 Kubernetes 위에 Helm으로 설치하고 멱등적으로 관리하는 절차를 안내합니다.

---

## 📌 버전 정의 명세

사용자 혼선을 예방하기 위해 본 패키지의 Chart 및 App/Image 버전을 다음과 같이 명확히 정의합니다.

* **Helm Chart Version**: `7.4.1` (argo-cd)
* **App Version**: `v2.12.0`
* **Container Image Version**: `v2.12.1`

---

## 0. 오프라인 설치 자산 준비 (외부망 - 인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(`.tar`)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 리눅스 PC**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

```bash
# 컴포넌트 루트 디렉토리에서 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

* **수집되는 자산:**
  * `./charts/argo-cd/` (Chart version 7.4.1, `helm pull --untar` 결과물)
  * `./images/` 하위 이미지 tar 파일들:
    * `quay.io_argoproj_argocd_v2.12.1.tar`
    * `public.ecr.aws_docker_library_redis_7.2.4-alpine.tar`
    * `public.ecr.aws_docker_library_haproxy_2.9-alpine.tar` (Redis HA 대응을 위한 예비 자산)

자산 수집이 완료되면 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 1. 이미지 로드 및 마이그레이션 (폐쇄망 환경)

반입 완료 후 환경에 따라 다음 모드 중 하나를 선택해 기동합니다.

```bash
# 이미지 마이그레이션 스크립트 권한 부여 및 실행
chmod +x ./images/upload_images_to_harbor_v3-lite.sh
sudo ./images/upload_images_to_harbor_v3-lite.sh
```

* **방식 1 (로컬 이미지 로드):** 실행 모드에서 `1`을 선택하여 containerd(`k8s.io` 네임스페이스)에 직접 로드합니다.
* **방식 2 (Harbor 레지스트리 업로드):** 실행 모드에서 `2`를 선택하여 Harbor 주소 및 프로젝트 경로를 대화형으로 입력 후 이미지 업로드를 완료합니다.

---

## 2. 대화형 멱등 설치 (install.sh)

설치 스크립트는 컴포넌트 루트에서 기동하며, 실행 시 자동으로 오프라인 에셋 존재 여부(`charts/argo-cd`, `images/`)를 사전 검증하여 안전하게 종료 흐름을 제어합니다.

```bash
chmod +x ./scripts/install.sh
./scripts/install.sh
```

### 주요 입력 항목 및 수명주기 동작

1. **이미지 소스:**
   * `1` (Harbor 레지스트리 사용)
   * `2` (로컬 tar 직접 import)
2. **스토리지 유형:**
   * `1) hostpath`: 워커 노드의 로컬 디스크 경로를 사용합니다.
   * `2) nas`: NFS 서버의 특정 경로를 직접 매핑합니다.
   * `3) nfs-dynamic`: 사전에 정의된 `StorageClass`를 통해 볼륨을 자동 할당받습니다.
   * `4) none`: 별도의 영구 저장소를 사용하지 않습니다.
3. **설정 영구화 및 멱등 배포:**
   * 입력된 설정 정보는 `install.conf` 및 `values-infra.yaml`에 보존되어, 향후 재기동 시 입력 프롬프트를 생략하고 업그레이드를 수행합니다.
4. **수명주기 메뉴:**
   * 기존 설치나 `install.conf` 감지 시 표준 메뉴(`1) Upgrade`, `2) Reinstall`, `3) Reset`, `4) Cancel`) 분기가 작동합니다.

---

## 3. 설치 확인

```bash
kubectl get pods -n argocd
kubectl get svc -n argocd
kubectl get httproute -n argocd
```

---

## 4. 초기 접속 및 비밀번호 변경

초기 비밀번호 확인:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

| 접속 방식 | 주소 | 비고 |
| :--- | :--- | :--- |
| **NodePort** | `http://<NODE_IP>:30001` | 일반 접속 |
| **도메인** | `http://argocd.devops.internal` | DNS/hosts 설정 필요 |

* 도메인 접속 시 클라이언트 PC의 hosts 파일에 추가해야 합니다:
  `<GATEWAY_IP>  argocd.devops.internal`

> [!NOTE]
> 최초 로그인 후 비밀번호를 변경하고 초기 Secret을 삭제하십시오.
> `kubectl delete secret argocd-initial-admin-secret -n argocd`

---

## 5. 서비스 삭제 및 초기화

### 일반 삭제 (인프라 설정 및 데이터 보존)

ArgoCD 릴리즈, NodePort 서비스, HTTPRoute 만 안전하게 제거하며, 로컬 설정 백업 자산인 `install.conf` / `values-infra.yaml` 및 `argocd` 네임스페이스(PVC 데이터 포함)는 **보존**합니다.

```bash
chmod +x ./scripts/uninstall.sh
./scripts/uninstall.sh
```

### 완전 초기화 (설정 및 데이터 완전 삭제)

헬름 릴리즈 삭제 후, 2차 정밀 y/N 프롬프트를 거쳐 `argocd` 네임스페이스 자체 및 로컬 설정 파일(`install.conf`, `values-infra.yaml`)까지 완벽하게 소거합니다.

```bash
./scripts/uninstall.sh --reset
```
