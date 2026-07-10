# Redis Stream v8.6.2-official (Standalone -> Helm Chart)

`redis:8.6.2-alpine3.23` 공식 이미지를 사용하는 Redis Sentinel HA 구성 패키지입니다.
기존 Standalone Kubernetes 매니페스트를 개선하여 **Helm Chart** 기반으로 동작하며, 외부 Bitnami Helm chart 의존성을 완전히 제거하여 폐쇄망에서도 독립적으로 동작합니다.

---

## 📌 아키텍처

```text
StatefulSet: redis-node (3 replicas)
  redis-node-0  → 초기 Master (또는 Sentinel이 지정한 Master)
  redis-node-1  → Replica
  redis-node-2  → Replica

StatefulSet: redis-sentinel (3 replicas)
  redis-sentinel-0/1/2  → mymaster 감시, quorum 2

Service: redis-headless  (ClusterIP: None)
Service: redis-sentinel-headless (ClusterIP: None)
Service: redis-stream-official (ClusterIP)
  → port 6379 (Redis), 26379 (Sentinel)

Namespace: redis-stream-official (기본값)
```

---

## 📂 디렉토리 구조

```text
redis-stream-8.6.2-official/
├── charts/
│   └── redis-sentinel/                 # 커스텀 Helm Chart (templates, Chart.yaml)
├── images/
│   ├── download_assets_offline.sh      # 이미지 및 에셋 수집 (외부망)
│   └── upload_images_to_harbor_v3-lite.sh
├── manifests/
│   ├── 10-pv-hostpath.yaml             # install.sh에서 변수 치환 후 사전 생성
│   └── 10-pv-nfs.yaml
├── scripts/
│   ├── install.sh                      # 멱등 대화형 설치 스크립트
│   ├── uninstall.sh                    # 삭제 및 초기화 스크립트
│   └── test-stream.sh                  # 스트림 테스트용 스크립트
├── values.yaml                         # Helm Chart 기본 프로덕션 값
├── README.md
└── install-guide.md                    # 세부 에어갭 설치 가이드
```

---

## 🛠️ 주요 표준화 사양

### 1. claimRef namespace 하드코딩 교정
PV 매니페스트 내 `claimRef.namespace` 변수를 `__NAMESPACE__` 치환자로 전환하여, 사용자가 네임스페이스를 다르게 배포하더라도 볼륨 바인딩 Pending 장애가 발생하지 않도록 조치했습니다.

### 2. values-infra.yaml 도입 및 비밀번호 저장 배제
보안 준수 사항에 따라 가변 설정 파일(`install.conf`)과 `values-infra.yaml` 에 `REDIS_PASSWORD` 평문 비밀번호를 절대 기록하지 않습니다. 대신 Upgrade 시 기존 K8s Secret(`redis-secret`)에서 패스워드를 복구하여 사용합니다.

### 3. 데이터 보존 기반 언인스톨 라이프사이클
일반 제거 시에는 릴리즈 정보만 소거하며 데이터 볼륨(PVC/PV)을 안전하게 보존하고, `--reset` 초기화 명령 시에만 2차 정밀 y/N 확인 프롬프트를 거쳐 데이터를 소거합니다.

---

## 🚀 빠른 시작

1. **설치 에셋 준비 (외부망):**
   ```bash
   ./scripts/download_assets_offline.sh
   ```

2. **이미지 업로드 (폐쇄망):**
   ```bash
   ./images/upload_images_to_harbor_v3-lite.sh
   ```

3. **대화형 설치 기동:**
   ```bash
   ./scripts/install.sh
   ```

상세한 설치 및 Failover 테스트 시나리오는 **[install-guide.md](./install-guide.md)**를 참조하세요.
