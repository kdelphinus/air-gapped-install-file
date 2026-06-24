# 🚀 Jenkins v2.555.3 오프라인 빌드 & 설치 가이드

폐쇄망 환경에서 OpenTofu가 포함된 Jenkins v2.555.3 (LTS)을 Kubernetes에 설치하는 통합 가이드입니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 가능 환경)

폐쇄망 내부 컴퓨터로 반입할 헬름 차트와 컨테이너 이미지(.tar) 자산이 없는 경우, **인터넷이 연결된 외부 리눅스 PC**에서 아래 단계를 진행해야 합니다.

### 0.1. 기본 이미지 및 Helm 차트 다운로드
```bash
cd jenkins-2.555.3/scripts/
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```
실행이 끝나면 `charts/`와 `images/` 폴더에 기본 헬름 차트 및 이미지 3종이 저장됩니다.

### 0.2. OpenTofu 내장 커스텀 이미지 조율 및 빌드
사용자의 인프라 사양(대상 CSP, Tofu 버전 등)에 맞추어 **가변형 이미지 빌드 툴체인**을 실행합니다.

```bash
cd ../jenkins-build/
chmod +x *.sh
sudo ./build-tofu-jenkins.sh
```

* **대화형 선택 옵션**:
  1. **OpenTofu 버전 지정**: 원하시는 버전을 기재합니다. (기본값: `1.6.0`)
  2. **설치 대상 CSP 프로바이더**: 띄어쓰기나 쉼표로 구분하여 입력합니다 (예: `aws,azure` 또는 `vmware`).
     * `aws`, `azure`, `vmware`, `openstack` 프로바이더 자동 매핑을 지원합니다.
  3. **플러그인 다운로드 여부**: `plugins.txt` 파일에 지정된 필수 Jenkins 플러그인 18종을 사전에 내려받아 이미지 내부에 패키징할지 선택합니다. (기본 권장)
* 빌드가 완료되면 `cmp-jenkins-full.tar` 파일이 자동 빌드되어 컴포넌트의 `../images/` 디렉터리로 이동됩니다.
* 이 상태에서 전체 컴포넌트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 1. 전제 조건 (폐쇄망 환경)

- Kubernetes v1.25.0 이상 클러스터 구성 완료
- Helm v3.14.0 이상 설치 완료
- `kubectl` CLI 사용 및 적절한 네임스페이스 권한 소유
- Harbor 사설 레지스트리 작동 상태 확인 (`<NODE_IP>:30002`)
- (HostPath PV 사용 시) `/data/jenkins` 디렉토리 사전 생성 권장

---

## 2. 1단계: 컨테이너 이미지 Harbor 업로드

폐쇄망 내 반입 완료 후, 컴포넌트 루트 디렉토리(`jenkins-2.555.3/`) 기준에서 마이그레이션 스크립트를 실행합니다.

```bash
# 이미지 업로드 스크립트 실행 (sudo 권한 필요)
sudo ./scripts/upload_images_to_harbor_v3-lite.sh
```
* **동작 원리**: 
  * docker, skopeo, ctr 도구를 자동 감지하여 업로드를 처리합니다.
  * **`skopeo`**가 설치된 머신인 경우, 로컬 containerd에 로드하지 않고 tar 아카이브에서 Harbor 레지스트리로 바로 이미지 복사(Copy)를 진행하여 업로드 속도를 극대화합니다.
  * 최후의 수단으로 `ctr`을 활용해 안전하게 Containerd에 로드합니다.

---

## 3. 2단계: 설치 및 구성 실행 (대화형)

설치 자동화 스크립트는 실행 시 필요한 설정값들을 대화식 CLI로 입력받아 설치 및 업그레이드를 수행합니다.

```bash
# 설치 스크립트 실행 (sudo 권한 필요)
sudo ./scripts/install.sh
```

### 주요 입력 정보 및 처리 방식
* **OpenTofu 커스텀 이미지 활성화 여부**: "y"를 선택하면, 빌드하여 업로드해 둔 `cmp-jenkins-full:2.555.3` 이미지를 `controller.image`로 오버라이드하여 배포합니다.
* **스토리지 유형**: 
  * `hostpath` 선택 시 워커 노드의 특정 로컬 디바이스 경로(기본 `/data/jenkins`)를 영구 마운트하며, `manifests/pv-volume.yaml` 리소스를 먼저 생성해줍니다.
  * `dynamic` 선택 시 사전에 준비된 `StorageClass`(예: NFS dynamic provisioner) 이름을 입력받아 동적으로 PVC를 구성합니다.
* **YAML 동기화**:
  * 입력된 설정은 `--set` 인자를 사용하는 대신 `values-override.yaml`을 생성하여 base인 `values.yaml`과 병합 배포하므로 **Single Source of Truth**가 보장됩니다.

---

## 4. 3단계: 초기 로그인 및 확인

설치가 완료되면 기동을 점검하고 초기 어드민 비밀번호를 획득합니다.

```bash
# 포드 및 서비스 기동 확인
kubectl get pods,svc -n jenkins

# 초기 관리자(admin) 비밀번호 조회
kubectl get secret jenkins -n jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 -d && echo
```

### 웹 UI 접속 방법
* **NodePort 방식**: `http://<NODE_IP>:30000`
* **도메인 라우팅 방식**: `http://jenkins.test.com`

---

## 5. 수동 설치 및 업그레이드 가이드 (Manual Installation & Upgrade)

자동화 스크립트 장애 대처용 수동 반영 가이드라인입니다.

### 5.1. 수동 설치 진행
1. `values.yaml` 내의 이미지 레지스트리 주소(예: `jenkins/jenkins` 등)를 사내 사설 Harbor 도메인 주소로 교체합니다.
   * OpenTofu 커스텀 이미지를 쓸 경우 `cmp-jenkins-full`로 변경합니다.
2. `values-override.yaml` 파일을 작성하여 로컬 사양(스토리지, NodePort 노출 사양)을 지정합니다.
   ```yaml
   controller:
     serviceType: "NodePort"
     nodePort: 30000
     persistence:
       enabled: true
       storageClass: "manual"
       size: "20Gi"
   ```
3. Kubernetes 볼륨 매니페스트 및 Helm 배포를 직접 적용합니다.
   ```bash
   # HostPath PV 적용 (HostPath 사용 시)
   kubectl apply -f ./manifests/pv-volume.yaml
   
   # Gradle 캐시 공유 PV/PVC 적용
   kubectl apply -f ./manifests/gradle-cache-pv-pvc.yaml -n jenkins
   
   # Helm 배포
   helm upgrade --install jenkins ./charts/jenkins \
     -n jenkins --create-namespace \
     -f ./values.yaml \
     -f ./values-override.yaml
   ```

---

## 6. 서비스 삭제 및 초기화

Jenkins를 완전히 제거하려면 다음 명령을 사용합니다.

```bash
# 리소스 삭제 (설정 파일 보존)
sudo ./scripts/uninstall.sh

# 완전 초기화 (설정 파일 및 로컬 백업 복원 등 완전 제거)
sudo ./scripts/uninstall.sh --reset
```
