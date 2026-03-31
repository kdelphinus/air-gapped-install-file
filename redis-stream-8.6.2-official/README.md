# Redis Stream 7.2 — 공식 이미지 방식 (Standalone -> Helm Chart)

## 개요

`redis:7.2` 공식 이미지를 사용하는 Redis Sentinel HA 구성입니다.

기존 Standalone Kubernetes 매니페스트를 개선하여 **Helm Chart** 기반으로 동작하며, Bitnami Helm chart 의존 없이 완전히 독립적으로 동작합니다.

## 아키텍처

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

Namespace: redis-stream-official
```

## 구성 요소 비교

| 항목 | 이 방식 (공식 이미지 + Helm) | 기존 방식 (Bitnami 커스텀 빌드) |
| :--- | :--- | :--- |
| 이미지 | `redis:7.2` 단독 | `redis:7.2` + bitnami rootfs |
| 배포 방식 | 자체 커스텀 Helm Chart | Bitnami chart |
| Sentinel | `redis-sentinel` 내장 | `bitnami/redis-sentinel` 별도 |
| Failover 강건성 | init container 스크립트 기반 | Bitnami start-node.sh 기반 |
| 이미지 빌드 | 불필요 | Dockerfile 빌드 필요 |

## 디렉토리 구조

```text
redis-stream-7.2-official/
├── charts/
│   └── redis-sentinel/                ← 커스텀 Helm Chart (templates, Chart.yaml)
├── images/
│   ├── docker.io_library_redis_7.2.tar        ← 설치 전 반입 필요
│   └── upload_images_to_harbor_v3-lite.sh
├── manifests/
│   ├── 10-pv-hostpath.yaml                    ← install.sh에서 변수 치환 후 사전 생성
│   └── 10-pv-nfs.yaml
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   └── test-stream.sh
├── values.yaml                            ← Helm Chart 기본 프로덕션 값
├── values-local.yaml                      ← 로컬 환경 개발 오버라이드 값
├── README.md
└── install-guide.md
```

## 빠른 시작

```bash
# 1. 이미지 Harbor 업로드
cd redis-stream-7.2-official
./images/upload_images_to_harbor_v3-lite.sh

# 2. 설치
./scripts/install.sh

# 3. 테스트
./scripts/test-stream.sh
```

자세한 내용은 `install-guide.md` 를 참조하세요.
