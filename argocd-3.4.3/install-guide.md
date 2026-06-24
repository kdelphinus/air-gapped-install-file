# 🚀 ArgoCD v3.4.3 오프라인 설치 가이드

폐쇄망 환경에서 ArgoCD v3.4.3(Helm Chart v9.5.21)을 Kubernetes 위에 설치 및 구성하는 절차를 안내합니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 가능 환경)

폐쇄망 내부 컴퓨터로 반입할 헬름 차트와 컨테이너 이미지(.tar) 자산이 없는 경우, **인터넷이 연결된 외부 리눅스 PC**에서 아래 단계를 먼저 진행해야 합니다.
(Docker, skopeo, ctr 중 사용 가능한 CLI 중 하나와 Helm v3 설치 필수)

```bash
# 스크립트 디렉토리로 이동
cd argocd-3.4.3/scripts/

# 실행 권한 부여
chmod +x ./scripts/download_assets_offline.sh

# 자산 다운로드 스크립트 실행 (sudo 권한 필요)
sudo ./scripts/download_assets_offline.sh
```

스크립트가 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 필수 컨테이너 이미지 6종의 `.tar` 파일이 생성됩니다. 이 전체 디렉토리를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 1. 전제 조건 (폐쇄망 환경)

- Kubernetes v1.25.0 이상 클러스터 구성 완료
- Helm v3.14.0 이상 설치 완료
- `kubectl` CLI 및 적절한 클러스터 권한 소유
- Harbor 사설 레지스트리 접근 가능
- (NAS 사용 시) 모든 워커 노드에 NFS 클라이언트 설치 완료

---

## 2. 1단계: 컨테이너 이미지 Harbor 업로드

폐쇄망 내 반입 완료 후, 컴포넌트 루트 디렉토리(`argocd-3.4.3/`) 기준에서 마이그레이션 스크립트를 실행합니다.

```bash
# 이미지 업로드 스크립트 실행 (sudo 권한 필요)
sudo ./scripts/upload_images_to_harbor_v3-lite.sh
```

### 업로드 동작 원리:
* 시스템 내 **docker**, **skopeo**, **ctr**를 차례대로 감지하여 가장 선호되는 도구로 업로드 및 푸시를 수행합니다.
* `skopeo` 사용이 가능한 경우, 로컬 런타임에 직접 로드하지 않고 tar 아카이브에서 직접 Harbor로 이미지 복사(Copy)를 진행하여 속도가 매우 빠릅니다.
* docker/skopeo가 존재하지 않는 원시 노드의 경우, 마지노선으로 **containerd의 `ctr`**를 사용하여 작업을 끝까지 보장합니다.

---

## 3. 2단계: 설치 및 구성 실행 (대화형)

설치 자동화 스크립트는 실행 시 이미지 레지스트리, 스토리지 클래스, 스토리지 용량, 서비스 노출 타입 등을 대화식 CLI로 입력받습니다.

```bash
# 설치 스크립트 실행 (sudo 권한 필요)
sudo ./scripts/install.sh
```

### 스크립트 동작 및 입력 가이드
1. **기존 상태 감지**: 기존 헬름 릴리즈가 존재하거나 `install.conf`가 존재할 시, `Upgrade(업그레이드)`, `Reinstall(재설치)`, `Reset(초기화)` 분기 메뉴를 제공합니다.
2. **설정값 수집 및 보존**: 사용자가 입력한 모든 정보는 `install.conf` 파일에 저장되어 멱등성을 보장합니다.
3. **YAML 동기화**: 입력된 설정은 `--set` 인자를 사용하는 대신 `values-override.yaml`을 생성하여 base인 `values.yaml`과 병합 배포하므로 **Single Source of Truth**가 보장됩니다.

---

## 4. 3단계: 초기 로그인 및 확인

설치가 완료되면 정상 기동을 점검합니다.

```bash
# 포드 상태 확인
kubectl get pods -n argocd

# 서비스 포트 확인
kubectl get svc -n argocd
```

### 초기 관리자(admin) 비밀번호 조회
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

### 웹 UI 접속 방법
* **NodePort 방식**: `http://<NODE_IP>:30001`
* **도메인 라우팅 방식**: `http://argocd.devops.internal`
  * (Envoy Gateway나 인그레스 게이트웨이 IP를 hosts 파일에 추가해야 합니다.)
  * 예: `192.168.1.10  argocd.devops.internal`

> [!WARNING]
> 최초 로그인 완료 후 보안을 위해 비밀번호를 반드시 새로 지정하고, 초기 패스워드 비밀번호 Secret을 안전하게 파괴하여 주십시오:
> `kubectl delete secret argocd-initial-admin-secret -n argocd`

---

## 5. 수동 설치 및 업그레이드 가이드 (Manual Installation & Upgrade)

자동 설치 스크립트를 사용하지 않고 수동으로 수립 및 반영할 경우의 가이드라인입니다.

### 5.1. 수동 설치 진행
1. `values.yaml` 내의 이미지 레지스트리 필드를 사설 Harbor 주소로 수동 교체합니다.
2. `values-override.yaml` 파일을 수동으로 작성하여 다음과 같이 로컬 사양을 추가합니다.
   ```yaml
   configs:
     cm:
       url: "https://argocd.devops.internal"
   server:
     service:
       type: NodePort
       nodePort: 30001
   ```
3. 차트 원본과 설정 파일을 활용해 Helm 릴리즈를 적용합니다.
   ```bash
   # CRD 우선 배포
   kubectl apply -f ./charts/argo-cd/templates/crds/ -n argocd
   
   # Helm 배포
   helm upgrade --install argocd ./charts/argo-cd \
     -n argocd --create-namespace \
     -f ./values.yaml \
     -f ./values-override.yaml
   ```

---

## 6. 서비스 삭제 및 초기화

ArgoCD를 완전히 삭제하려면 아래 명령을 사용합니다.

```bash
# 리소스 삭제 (설정 파일 보존)
sudo ./scripts/uninstall.sh

# 완전 초기화 (설정 파일 및 로컬 백업 복원 등 완전 제거)
sudo ./scripts/uninstall.sh --reset
```
