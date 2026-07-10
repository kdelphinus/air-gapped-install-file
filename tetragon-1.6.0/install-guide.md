# 🚀 Tetragon 폐쇄망 설치 가이드 (v1.6.0)

eBPF 기반 실시간 보안 및 차단 도구 Tetragon을 폐쇄망 환경의 Kubernetes에 배포하는 절차입니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 스크립트 실행 권한 부여 및 자산 다운로드
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

> **에어갭 완결성 보완**: `download_assets_offline.sh`는 `tetragon`, `tetragon-operator` 외에 stdout export sidecar에 필요한 `hubble-export-stdout:v1.1.0` 이미지까지 자동으로 수집합니다.

---

## 1. 사전 요건

- `kubectl` CLI 사용 가능
- `helm` v3.14.0 이상
- 로컬 Harbor 레지스트리 접근 가능 (`<HARBOR_REGISTRY>`)
- eBPF/BTF 지원 커널 (5.10+)
  ```bash
  uname -r
  ls /sys/kernel/btf/vmlinux   # 존재해야 함
  ```

---

## 2. 1단계: 이미지 Harbor 업로드 (폐쇄망 환경)

모든 작업은 컴포넌트 루트 디렉토리(`tetragon-1.6.0/`)에서 실행합니다.

```bash
# 1. 수집된 모든 이미지 로컬 containerd(k8s.io)에 import
for f in images/*.tar; do sudo ctr -n k8s.io images import "$f"; done

# 2. 이미지 마이그레이션 및 Harbor 푸시 실행
chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

업로드 대상 이미지:

| 파일 | 이미지 |
| :--- | :--- |
| `tetragon-v1.6.0.tar` | `quay.io/cilium/tetragon:v1.6.0` |
| `tetragon-operator-v1.6.0.tar` | `quay.io/cilium/tetragon-operator:v1.6.0` |
| `hubble-export-stdout-v1.1.0.tar` | `quay.io/cilium/hubble-export-stdout:v1.1.0` |

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
  * 입력된 설정은 base인 `values.yaml`을 수정하지 않고, 가변 인프라 설정 전용 파일인 `values-infra.yaml`을 생성하여 병합 배포하므로 **Single Source of Truth**가 보장됩니다.
  * 생성된 `values-infra.yaml` 및 `install.conf`는 일반 삭제 시에도 디렉토리에 보존되어 재설치 및 업그레이드 시 멱등 배포를 보장하며, 오직 `--reset` 초기화 명령 시에만 소거됩니다.
* **보안 정책(TracingPolicy) 연동**:
  * 설치 과정에서 민감 파일 차단 정책(`block-sensitive-read`) 적용 동의 여부를 묻고, 선택값(`APPLY_POLICY`)을 `install.conf` 에 영구 기록하여 업그레이드 시 상태를 멱등하게 유지합니다.

---

## 4. 3단계: 차단 정책 테스트

Tetragon은 기본 차단 정책이 생성되지 않으므로, 알림 및 강제 종료(Sigkill) 동작을 검증하기 위해 `TracingPolicy`를 적용합니다.

### 4.1. 제공 차단 정책 (`manifests/block-sensitive-read.yaml`)
`/etc/shadow` 파일에 접근하는 비정상적인 행위를 차단하되, 시스템 인증 프로세스(`sudo`, `su`, `unix_chkpwd` 등)는 영향이 가지 않도록 예외 처리된 테스트용 안전 정책입니다.

### 4.2. 정책 적용 상태 조회
```bash
kubectl get tracingpolicy
```

### 4.3. 차단 동작 검증
임시 파드를 띄워 `/etc/shadow` 읽기를 시도합니다.
```bash
kubectl run test-block --image=busybox --rm -it --restart=Never -- cat /etc/shadow
# 예상 결과: cat 프로세스가 Sigkill로 즉시 종료되며 터미널에 "Killed" 출력
```

---

## 5. 수동 설치 및 업그레이드 가이드 (Manual Installation & Upgrade)

자동화 스크립트 장애 대처용 수동 반영 가이드라인입니다.

### 5.1. 수동 설치 진행
1. `values.yaml` 을 수정하지 않고 그대로 두고, `values-infra.yaml` 파일을 작성하여 로컬 사양(이미지 레지스트리 경로)을 오버라이드합니다.
   * **3대 이미지 오버라이드 스펙**: stdout exporter 이미지를 포함하여 아래 옵션 블록을 작성합니다.
   ```yaml
   tetragon:
     image:
       override: "192.168.1.10:30002/library/tetragon:v1.6.0"

   tetragonOperator:
     image:
       override: "192.168.1.10:30002/library/tetragon-operator:v1.6.0"

   export:
     stdout:
       image:
         override: "192.168.1.10:30002/library/hubble-export-stdout:v1.1.0"
   ```
2. Helm 배포를 직접 적용합니다.
   ```bash
   # Helm 배포 (멱등 배포)
   helm upgrade --install tetragon ./charts/tetragon \
     -n kube-system \
     -f ./values.yaml \
     -f ./values-infra.yaml
   ```

---

## 6. 서비스 삭제 및 초기화

Tetragon 스택을 완전히 제거하려면 다음 명령을 사용합니다.

```bash
# 리소스 삭제 (설정 파일 및 TracingPolicy 보존하여 운영 영향 최소화)
sudo ./scripts/uninstall.sh

# 완전 초기화 (샘플 TracingPolicy 삭제 확인 후 설정 파일 완전 제거)
sudo ./scripts/uninstall.sh --reset
```

---

## 별첨: Grafana 연동 체크리스트

Tetragon metrics를 Prometheus + Grafana 스택에 연동할 때 확인할 항목입니다.

> Tetragon 차트에는 Grafana 대시보드가 내장돼 있지 않습니다. ServiceMonitor로 metrics 수집 후 커뮤니티 대시보드를 import하거나 직접 작성해야 합니다.

| 항목 | 내용 | 비고 |
| :--- | :--- | :--- |
| metrics 엔드포인트 | `tetragon:2112/metrics` | 설치 시 자동 생성 |
| operator metrics | `tetragon-operator-metrics:2113/metrics` | 설치 시 자동 생성 |
| ServiceMonitor | Prometheus scrape 설정 생성 필요 | 미생성 |
| 대시보드 | 차트 내장 없음 — 별도 준비 필요 | 없음 |

### 연동 순서
1. ServiceMonitor 생성으로 Prometheus scrape 활성화
2. Prometheus에서 `tetragon` target이 UP 상태인지 확인
3. Grafana에서 대시보드 import 또는 직접 작성
