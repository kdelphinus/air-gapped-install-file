# Redis Stream (HA)

본 컴포넌트는 단일 Kafka/Zookeeper 아키텍처를 대체하기 위해 구성된 **Redis Stream 7.2.4 (Master-Replica-Sentinel HA)** 클러스터입니다.

## 주요 특징

- **고가용성**: Master 1 + Replica 2 + Sentinel 3 구성을 통한 자동 Failover 지원
- **환경 최적화**: 운영(Harbor) 및 로컬(k3s/docker) 환경에 최적화된 설치 스크립트 제공
- **데이터 보장**: `AOF` 기반 영속성 및 `HostPath PV` (Node Affinity) 지원
- **OOM 방지**: `MAXLEN` 기반 스트림 로그 트리밍 전략 기본 적용

## 디렉토리 구조

```text
redis-stream-7.2/
├── charts/redis/           # Bitnami Redis Helm 차트
├── images/                 # Redis 이미지 및 Harbor 업로드 스크립트
├── manifests/              # PV 매니페스트 및 테스트 파드
├── scripts/                # 설치(install.sh), 테스트(test-stream.sh) 등 운영 스크립트
├── examples/spring-boot/   # At-Least-Once 구현 예제 프로젝트
├── values.yaml             # 운영 환경 설정
├── values-local.yaml       # 로컬 테스트 환경 설정 (Override)
└── README.md               # 서비스 명세
```

## 빠른 시작 (로컬 테스트)

```bash
# 1. 이미지 임포트 (k3s 예시)
sudo k3s ctr images import images/*.tar

# 2. 설치 (Local 모드 선택)
./scripts/install.sh local

# 3. 검증
./scripts/test-stream.sh local
```

## 접속 정보 및 포트

- **Sentinel 엔드포인트**: `redis-stream.redis-stream.svc:26379`
- **Master Set 이름**: `mymaster`
- **Port**: 6379 (Redis), 26379 (Sentinel)

## 상세 가이드

더 자세한 설치 및 운영 방법은 [설치 가이드(install-guide.md)](./install-guide.md)를 참조하세요.
