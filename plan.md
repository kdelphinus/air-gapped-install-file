Kafka → Redis Stream 전환 계획

Context

현재 tmp/kafka/(Kafka 3.3.1 단일 브로커 + Zookeeper 의존)를 Redis Streams(7.2.4)로 전환.
Kafka 대비 인프라 복잡도를 낮추면서 at-least-once 보장, 3대 HA, 네트워크 장애 시 메시지 보존을 충족해야 함.

At-Least-Once 보장 — Redis Streams 현실

┌───────────────┬──────────────────────────────────┬─────────────────────────────────────────────────┐
│     영역      │              Kafka               │                  Redis Streams                  │
├───────────────┼──────────────────────────────────┼─────────────────────────────────────────────────┤
│ Consumer      │ Consumer Group + offset commit   │ Consumer Group + XACK + XAUTOCLAIM (동일 수준)  │
├───────────────┼──────────────────────────────────┼─────────────────────────────────────────────────┤
│ Producer      │ acks=all + 브로커 ISR 자동 보장  │ XADD + WAIT(동기 복제) 필요 — 앱 레벨 구현      │
├───────────────┼──────────────────────────────────┼─────────────────────────────────────────────────┤
│ 네트워크 장애 │ Producer 내부 버퍼 + 자동 재전송 │ 내장 없음 — 앱에서 로컬 버퍼 + 재시도 구현 필수 │
├───────────────┼──────────────────────────────────┼─────────────────────────────────────────────────┤
│ 영속성        │ 디스크 기반 로그                 │ AOF(appendfsync everysec) — 최대 1초 유실 가능  │
└───────────────┴──────────────────────────────────┴─────────────────────────────────────────────────┘

결론: Redis Streams로 at-least-once 가능하지만, Producer 쪽은 앱 코드에서 보장해야 함.
Consumer 쪽은 네이티브 지원 (Consumer Group + XACK + XAUTOCLAIM).

⚠️ 중요 주의사항 (Kafka 대비):
1. Consumer 자동 리밸런싱 부재: Kafka와 달리 Redis는 Consumer가 죽었을 때 자동으로 파티션을 재할당하지 않습니다. 따라서 앱 레벨에서 주기적인 XAUTOCLAIM으로 Zombie 메시지를 회수해야 합니다.
2. OOM 방지 (필수): XADD 시 반드시 MAXLEN 파라미터를 지정해야 합니다 (예: MAXLEN ~ 100000). 지정하지 않으면 메모리가 무한 증가하여 Redis 전체가 다운(OOM)될 수 있습니다.

---
Phase 1: 디렉토리 구조 및 차트 준비

신규 컴포넌트: redis-stream-7.2/

redis-stream-7.2/
├── charts/redis/           ← Bitnami Redis 차트 (gitlab-18.7에서 복사)
├── images/
│   ├── *.tar               ← Redis 이미지 tar 파일들
│   └── upload_images_to_harbor_v3-lite.sh
├── manifests/
│   ├── redis-stream-pv.yaml
│   └── redis-stream-test-pod.yaml
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   ├── setup-host-dirs.sh
│   └── test-stream.sh
├── examples/spring-boot/
│   ├── pom.xml
│   └── src/main/
│       ├── java/com/example/redisstream/
│       │   ├── RedisStreamApplication.java
│       │   ├── config/RedisStreamConfig.java
│       │   ├── producer/RedisStreamProducer.java
│       │   └── consumer/RedisStreamConsumer.java
│       └── resources/application.yml
├── values.yaml
├── values-local.yaml
├── README.md
└── install-guide.md

차트 소스

gitlab-18.7/charts/gitlab/charts/redis/ → redis-stream-7.2/charts/redis/로 복사.
Bitnami Redis 차트로 master-replica-sentinel 토폴로지 네이티브 지원.

이미지

┌────────────────────────┬─────────────────────┬─────────────────────┬──────────────────────┐
│         이미지         │        태그         │        소스         │         비고         │
├────────────────────────┼─────────────────────┼─────────────────────┼──────────────────────┤
│ bitnami/redis          │ 7.2.4-debian-12-r9  │ gitlab-18.7/images/ │ 있음                 │
├────────────────────────┼─────────────────────┼─────────────────────┼──────────────────────┤
│ bitnami/redis-sentinel │ 7.2.4-debian-12-r7  │ 없음                │ 외부에서 export 필요 │
├────────────────────────┼─────────────────────┼─────────────────────┼──────────────────────┤
│ bitnami/redis-exporter │ 1.58.0-debian-12-r4 │ gitlab-18.7/images/ │ 선택                 │
└────────────────────────┴─────────────────────┴─────────────────────┴──────────────────────┘

주의: redis-sentinel 이미지가 프로젝트에 없음.
외부망에서 docker pull bitnami/redis-sentinel:7.2.4-debian-12-r7 → docker save → 반입 필요.
→ install-guide.md에 반입 절차 문서화, images/ 디렉토리에 tar 위치 안내.

---
Phase 2: values.yaml (운영)

image:
 registry: "<NODE_IP>:30002"
 repository: library/redis
 tag: "7.2.4-debian-12-r9"
 pullPolicy: IfNotPresent

architecture: replication

auth:
 enabled: true
 sentinel: true
 # password는 install.sh에서 입력받아 --set으로 전달

# At-least-once 핵심: AOF 활성화
commonConfiguration: |-
 appendonly yes
 save ""
 appendfsync everysec
 maxmemory-policy noeviction
 stream-node-max-bytes 4096
 stream-node-max-entries 100

master:
 persistence:
   enabled: true
   storageClass: ""
   size: 10Gi
 resources:
   requests: { cpu: 250m, memory: 512Mi }
   limits: { cpu: 1000m, memory: 2Gi }

replica:
 replicaCount: 2
 persistence:
   enabled: true
   storageClass: ""
   size: 10Gi
 resources:
   requests: { cpu: 250m, memory: 512Mi }
   limits: { cpu: 1000m, memory: 2Gi }

sentinel:
 enabled: true
 image:
   registry: "<NODE_IP>:30002"
   repository: library/redis-sentinel
   tag: "7.2.4-debian-12-r7"
 masterSet: mymaster
 quorum: 2
 downAfterMilliseconds: 5000
 failoverTimeout: 60000
 resources:
   requests: { cpu: 100m, memory: 128Mi }
   limits: { cpu: 250m, memory: 256Mi }

Phase 3: values-local.yaml (로컬 테스트)

- replica.replicaCount: 1 (최소 HA)
- 리소스 절반, PV 크기 2Gi
- Sentinel 활성화 유지 (HA 테스트 가능)

---
Phase 4: 매니페스트

manifests/redis-stream-pv.yaml

- Master PV 1개 + Replica PV 2개 (총 3개)
- persistentVolumeReclaimPolicy: Retain
- hostPath + nodeAffinity (HostPath 선택 시)
- claimRef로 StatefulSet PVC 이름에 매칭:
 - redis-data-redis-stream-master-0
 - redis-data-redis-stream-replicas-0
 - redis-data-redis-stream-replicas-1

manifests/redis-stream-test-pod.yaml

- redis-cli가 포함된 경량 Pod (스트림 테스트용)

---
Phase 5: 스크립트

scripts/install.sh

1. 네임스페이스 생성 (redis-stream)
2. 스토리지 타입 선택 (HostPath / NFS) — harbor install.sh 패턴 재사용
3. PV 적용
4. Redis 비밀번호 입력 (인터랙티브)
5. helm upgrade --install redis-stream ./charts/redis -f values.yaml -n redis-stream --set auth.password=... --timeout 600s
6. Pod Ready 대기
7. 접속 정보 출력 (Sentinel: redis-stream.redis-stream.svc:26379)

scripts/uninstall.sh

- Helm uninstall + PVC/PV 삭제 확인

scripts/setup-host-dirs.sh

- HostPath 사용 시 /data/redis-stream/{master,replica-0,replica-1} 생성

scripts/test-stream.sh

Redis Streams 전체 라이프사이클 검증:

1. XGROUP CREATE mystream mygroup $ MKSTREAM
2. XADD mystream MAXLEN ~ 100000 * key value-{1..5} (5개 메시지 생산, OOM 방지)
3. WAIT 1 5000 (동기 복제 확인)
4. XREADGROUP GROUP mygroup consumer1 COUNT 5 STREAMS mystream > (소비)
5. XPENDING mystream mygroup (ACK 전 pending 확인)
6. XACK mystream mygroup {id} (ACK 처리)
7. XINFO STREAM mystream (스트림 상태 확인)
8. 결과 요약 출력

---
Phase 6: Spring Boot 예시 프로젝트 (빌드 가능)

examples/spring-boot/ 디렉토리에 빌드 가능한 Maven 프로젝트를 생성한다.

프로젝트 구조

examples/spring-boot/
├── pom.xml
└── src/main/
   ├── java/com/example/redisstream/
   │   ├── RedisStreamApplication.java
   │   ├── config/RedisStreamConfig.java
   │   ├── producer/RedisStreamProducer.java
   │   └── consumer/RedisStreamConsumer.java
   └── resources/
       └── application.yml

pom.xml

- Spring Boot 3.2.x (Java 17)
- 의존성: spring-boot-starter-data-redis, spring-boot-starter-web
- Lettuce 클라이언트 (Spring Data Redis 기본)
- 폐쇄망 빌드 시 로컬 Maven 저장소 사용 안내 주석 포함

application.yml

spring:
 data:
   redis:
     sentinel:
       master: mymaster
       nodes: redis-stream.redis-stream.svc:26379
     password: "${REDIS_PASSWORD}"
     timeout: 5000ms

RedisStreamProducer.java

핵심: at-least-once Producer 패턴

- XADD 시 반드시 MAXLEN 지정 (예: MAXLEN ~ 100000)하여 OOM 방지 + WAIT 1 5000
- 실패 시 ConcurrentLinkedQueue 로컬 버퍼에 저장
- @Scheduled 백그라운드 스레드가 버퍼 drain → 재전송
- 메시지에 sequence number 포함 (순서 보장 검증용)

RedisStreamConsumer.java

핵심: at-least-once Consumer 패턴

- StreamMessageListenerContainer + XREADGROUP
- 처리 성공 후 XACK (수동 ACK)
- @Scheduled로 30초 이상 pending 메시지 XAUTOCLAIM (죽은 consumer 복구)
- 메시지 ID 기반 중복 처리 (멱등성)

RedisStreamConfig.java

- LettuceConnectionFactory + RedisSentinelConfiguration
- StreamMessageListenerContainer Bean 설정

---
Phase 7: 문서

README.md

- 아키텍처 개요 (Master 1 + Replica 2 + Sentinel 3)
- Redis Streams vs Kafka 비교표
- 접속 정보, 포트, 네트워크 명세

install-guide.md

1. 전제 조건
2. 이미지 업로드 (images/ → Harbor)
3. 호스트 디렉토리 생성 (HostPath 시)
4. 설치 (scripts/install.sh)
5. 스트림 테스트 (scripts/test-stream.sh)
6. Spring Boot 연동 가이드
7. At-Least-Once 보장 설정 및 Kafka 대비 제한사항 (핵심 섹션 - Consumer 리밸런싱 부재, MAXLEN을 통한 OOM 방지 필수 등)
8. 트러블슈팅
9. 삭제

---
수정/생성 대상 파일 요약

┌──────────────────────────────────────────────────────────────────────────┬────────────────────────────┐
│                                   파일                                   │            작업            │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/charts/redis/                                           │ gitlab에서 차트 복사       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/images/                                                 │ tar 복사 + upload 스크립트 │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/manifests/redis-stream-pv.yaml                          │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/manifests/redis-stream-test-pod.yaml                    │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/scripts/install.sh                                      │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/scripts/uninstall.sh                                    │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/scripts/setup-host-dirs.sh                              │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/scripts/test-stream.sh                                  │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/examples/spring-boot/pom.xml                            │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/examples/spring-boot/src/main/java/**/*.java            │ 신규 (4개)                 │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/examples/spring-boot/src/main/resources/application.yml │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/values.yaml                                             │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/values-local.yaml                                       │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/README.md                                               │ 신규                       │
├──────────────────────────────────────────────────────────────────────────┼────────────────────────────┤
│ redis-stream-7.2/install-guide.md                                        │ 신규                       │
└──────────────────────────────────────────────────────────────────────────┴────────────────────────────┘

---
검증 방법

1. scripts/test-stream.sh — XADD/XREADGROUP/XACK/WAIT 전체 라이프사이클
2. XPENDING 으로 ACK 전 메시지 pending 확인 (at-least-once consumer 검증)
3. WAIT 반환값 확인 — replica 복제 완료 수 (at-least-once producer 검증)
4. Master pod 강제 삭제 → Sentinel failover → 메시지 유실 없는지 확인
5. Spring Boot 예시 코드 컴파일 검증 (문법 확인)