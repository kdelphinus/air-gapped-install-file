# 🚀 Monitoring 오프라인 설치 가이드 (kube-prometheus-stack)

폐쇄망 환경에서 kube-prometheus-stack을 사용하여 통합 모니터링(Prometheus/Grafana)을 구축하는 절차입니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 1. 전제 조건

- Kubernetes 클러스터 구성 완료 (1.25.0 이상 권장)
- `kubectl` 및 `helm` CLI 사용 가능
- Harbor 레지스트리 구축 완료 (`<NODE_IP>:30002`)
- 인터넷 연결 환경에서 이미지 및 Helm 차트 사전 준비 완료

---

## 2. 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리(`monitoring-0.89.0/`)에서 실행합니다.

```bash
# 1. 이미지 로드 (ctr 사용)
for f in images/*.tar; do sudo ctr -n k8s.io images import "$f"; done

# 2. 이미지 마이그레이션 및 Harbor 푸시 실행
chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

---

## 3. 2단계: 설치 실행 (대화형)

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# 헬름 설치 (values-infra.yaml 자동 생성 및 base values.yaml 병합)
chmod +x scripts/install.sh
./scripts/install.sh
```

### 주요 입력 정보 및 처리 방식
* **이미지 소스**:
  * Harbor 방식은 `<HARBOR_REGISTRY>/<HARBOR_PROJECT>/...` 이미지를 사용합니다.
  * 로컬 방식은 각 노드에 사전 로드된 기본 컨테이너 이미지를 활용합니다.
* **설정 동기화**:
  * 입력된 설정은 base인 `values.yaml`을 변경하지 않고, 가변 인프라 설정 전용 파일인 `values-infra.yaml`을 생성하여 병합 배포하므로 **Single Source of Truth**가 보장됩니다.
  * 생성된 `values-infra.yaml` 및 `install.conf`는 일반 삭제 시에도 디렉토리에 보존되어 재설치 및 업그레이드 시 멱등 배포를 보장하며, 오직 `--reset` 초기화 명령 시에만 소거됩니다.

---

## 4. 3단계: HTTPRoute 적용 (Envoy Gateway 사용 시)

Envoy Gateway를 Ingress로 사용하는 경우 HTTPRoute를 적용합니다.
`manifests/httproute.yaml` 상단의 hostname을 실제 도메인으로 수정한 뒤 실행합니다.

```bash
# hostname 확인 및 수정
# grafana.devops.internal / prometheus.devops.internal / alertmanager.devops.internal
kubectl apply -f manifests/httproute.yaml
```

---

## 5. 수동 설치 및 업그레이드 가이드 (Manual Installation & Upgrade)

자동화 스크립트 장애 대처용 수동 반영 가이드라인입니다.

### 5.1. 수동 설치 진행
1. `values.yaml` 을 수정하지 않고 그대로 두고, `values-infra.yaml` 파일을 작성하여 로컬 사양(이미지 레지스트리 경로, 스토리지 클래스, 스토리지 크기)을 오버라이드합니다.
   * **보안 가이드**: Grafana의 초기 `adminPassword`는 values 파일에 평문 기재하지 않고 비워둠으로써, Helm 차트 템플릿의 무작위 비밀번호 자동 생성 기능을 보존 계승합니다.
   ```yaml
   global:
     imageRegistry: "192.168.1.10:30002"
     imageNamePrefix: "library/"
   prometheus:
     prometheusSpec:
       storageSpec:
         volumeClaimTemplate:
           spec:
             storageClassName: "manual"
             accessModes: ["ReadWriteOnce"]
             resources:
               requests:
                 storage: "50Gi"
   grafana:
     persistence:
       enabled: true
       storageClassName: "manual"
       size: "10Gi"
   ```
2. Kubernetes 영구 볼륨 매니페스트 및 Helm 배포를 직접 적용합니다.
   ```bash
   # 1. 네임스페이스 생성
   kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

   # 2. Prometheus 및 Grafana용 정적 PV 배포 (HostPath/정적 PV 환경 시)
   # (manifests 디렉토리에 정의해 둔 영구 볼륨 리소스를 적용합니다)
   kubectl apply -f ./manifests/pv-volume.yaml

   # 3. Helm 배포 (멱등 배포)
   helm upgrade --install prometheus ./charts/kube-prometheus-stack \
     -n monitoring \
     -f ./values.yaml \
     -f ./values-infra.yaml
   ```

---

## 6. 서비스 삭제 및 초기화

Monitoring 스택을 완전히 제거하려면 다음 명령을 사용합니다.

```bash
# 리소스 삭제 (설정 파일 및 데이터 볼륨 보존)
sudo ./scripts/uninstall.sh

# 완전 초기화 (설정 파일 및 데이터 볼륨 완전 제거)
sudo ./scripts/uninstall.sh --reset
```

---

## 7. 설치 확인 및 접속

```bash
# Grafana 접속 (Port-forward 테스트)
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
```

### 초기 로그인 및 비밀번호 획득
* **ID**: `admin`
* **Password**: `values-infra.yaml`에 패스워드를 지정하지 않았으므로, 헬름이 자동 생성한 K8s Secret에서 디코딩하여 조회합니다.
  ```bash
  kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d && echo
  ```
