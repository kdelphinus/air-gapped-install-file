# Cilium 1.19.3 Air-Gapped 설치 가이드

본 문서는 외부 인터넷 연결이 차단된 **폐쇄망(Air-Gapped) 쿠버네티스 환경**에서 Cilium 1.19.3을 성공적으로 설치하기 위한 상세 가이드를 제공합니다.

---

## 📋 사전 준비 사항

### 1. 이미지 및 헬름 차트
본 패키지(`cilium-1.19.3/`)에는 다음 자산이 이미 포함되어 있습니다.
- `charts/cilium`: Cilium 1.19.3 Helm Chart
- `images/*.tar`: 필수 컨테이너 이미지 (Cilium, Operator, Hubble, Envoy 등)

### 2. 하버(Harbor) 레지스트리 준비
폐쇄망 내부의 Harbor 레지스트리에 이미지를 업로드해야 합니다.
1. `images/upload_images_to_harbor_v3-lite.sh`를 실행하여 이미지를 업로드합니다.
2. 업로드 시 사용한 **레지스트리 주소**와 **프로젝트명**을 기억하십시오.

---

## 🛠️ 단계별 설치 프로세스

### Step 1: 설치 환경 변수 결정
설치 스크립트 실행 전, 자신의 쿠버네티스 클러스터 인프라에 맞는 다음 설정값들을 미리 확인하십시오.

| 설정 항목 | 설명 | 예시 (Bare-metal) | 예시 (K3s/WSL2) |
| :--- | :--- | :--- | :--- |
| **API 서버 호스트** | 마스터 노드의 IP 주소 | `192.168.1.10` | `172.30.235.200` |
| **Pod CIDR** | 포드용 네트워크 대역 | `10.244.0.0/16` | `10.42.0.0/16` |
| **MTU** | 최대 전송 단위 (기본 1500) | `1500` | `1450` (VXLAN 오버헤드 고려) |

### Step 2: 설치 스크립트 실행
대화형 스크립트를 통해 환경에 맞는 값을 입력하여 설치를 진행합니다.

```bash
cd scripts/
chmod +x install.sh
sudo ./install.sh
```

### Step 3: 설치 옵션 선택
1. **이미지 소스**: `1) Harbor` 선택
2. **Harbor 정보**: 주소 및 프로젝트 입력
3. **네트워크 변수**: 위 Step 1에서 확인한 API 호스트, Pod CIDR, MTU 입력
4. **Hubble 활성화**: 가시성 도구 설치 여부 (`y` 권장)

---

## ✅ 설치 검증 및 트러블슈팅

### 1. 포드 상태 확인
모든 Cilium 관련 포드가 `Running` 상태여야 합니다.
```bash
kubectl get pods -n kube-system -l "app.kubernetes.io/part-of=cilium"
```

### 2. 포트 충돌 이슈 (FailedScheduling)
재설치 시 `0/1 nodes are available: 1 node(s) didn't have free ports...` 에러와 함께 포드가 `Pending` 상태로 머물 수 있습니다.
- **원인**: 이전 Cilium 설치 시 생성된 바이너리 프로세스가 호스트 포트(9234, 9963 등)를 여전히 점유하고 있는 경우입니다.
- **해결**: `install.sh`의 `2) 재설치` 또는 `3) 초기화` 옵션을 사용하면 자동으로 해당 프로세스를 찾아 종료합니다. 

#### ⚠️ 주의: 포트를 변경한 경우
만약 `values.yaml`에서 Cilium의 기본 포트를 변경하여 운영 중이라면, **스크립트의 자동 클린업이 작동하지 않습니다.** 이 경우 아래 명령어를 사용하여 직접 포트 점유 여부를 확인하고 종료해야 합니다.

| 컴포넌트 | 기본 포트 | 용도 |
| :--- | :--- | :--- |
| Operator | 9234, 9963 | Health Check, Metrics |
| Agent | 4240, 4244 | Health, Hubble Server |
| Agent API | 9876, 9890 | Local API, Metrics |

**수동 해결 명령어:**
```bash
# 특정 포트(예: 9234)를 사용하는 프로세스 강제 종료
sudo fuser -k -9 9234/tcp
```

### 3. Cilium 에이전트 상태 상세 확인
```bash
kubectl exec -it -n kube-system ds/cilium -- cilium status
```

---

## ⚠️ 주의 및 제약 사항

1. **자동 환경 감지 (K3s / K8s)**: 설치 스크립트(`install.sh`)가 실행 중인 노드의 정보를 기반으로 K3s 환경을 자동 감지합니다. K3s로 확인될 경우 K3s 전용 CNI 경로(`/var/lib/rancher/k3s/data/cni` 등)를 Helm 설정에 동적으로 추가하여 설치합니다.
2. **Kube-proxy 대체**: 본 설정은 `kubeProxyReplacement: true`를 기본으로 합니다. 기존 클러스터에 `kube-proxy`가 실행 중이라면, Cilium 설치 후 중복 작동 여부를 검토하십시오.
3. **HTTPS Digest**: 폐쇄망에서는 외부 다이제스트 체크가 불가능하므로, `values.yaml`에서 `useDigest: false`를 강제 적용하였습니다.
4. **네트워크 단절**: CNI 설치/재설치 중에는 노드 및 포드 간 통신이 일시적으로 중단됩니다.
