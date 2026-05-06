# Redis Stream 서비스 개발자 가이드 (Kafka 전환 및 실무 구현)

작성일: 2026-03-30

---

## 목차

- [Redis Stream 서비스 개발자 가이드 (Kafka 전환 및 실무 구현)](#redis-stream-서비스-개발자-가이드-kafka-전환-및-실무-구현)
  - [목차](#목차)
  - [1. 인프라 구조 및 장애 조치 (HA)](#1-인프라-구조-및-장애-조치-ha)
    - [1.1 HA 구성 아키텍처](#11-ha-구성-아키텍처)
  - [1.2 데이터 영속성 및 용량 관리 (Infra vs App)](#12-데이터-영속성-및-용량-관리-infra-vs-app)
    - [\[Bowl: 인프라 설정\] Redis 서버 영속성 (Helm Chart / redis.conf)](#bowl-인프라-설정-redis-서버-영속성-helm-chart--redisconf)
      - [영속성 모드 비교 (RDB / AOF / Hybrid)](#영속성-모드-비교-rdb--aof--hybrid)
      - [영속성 설정 항목 (Helm values.yaml → redis.config)](#영속성-설정-항목-helm-valuesyaml--redisconfig)
    - [\[Food: 앱 설정\] 스트림 데이터 제어 (Spring Boot / Java)](#food-앱-설정-스트림-데이터-제어-spring-boot--java)
      - [1.2.5 데이터 제거 전략 (Retention)](#125-데이터-제거-전략-retention)
    - [1.3 물리적 인프라 요구사항 (K8s \& Storage)](#13-물리적-인프라-요구사항-k8s--storage)
    - [💡 운영자 체크리스트 (Summary)](#-운영자-체크리스트-summary)
  - [2. Kafka vs Redis Stream 핵심 개념 매핑](#2-kafka-vs-redis-stream-핵심-개념-매핑)
    - [2.1 파티션 및 확장 전략 (Partitioning Strategy)](#21-파티션-및-확장-전략-partitioning-strategy)
      - [전략 1: Consumer Group 확장 (Scale-out)](#전략-1-consumer-group-확장-scale-out--대부분의-경우-권장)
      - [전략 2: 멀티 키 파티셔닝](#전략-2-멀티-키-파티셔닝--초고속-쓰기수천-tps-이상-필요-시)
  - [3. Spring Boot 프로젝트 설정 및 Fail-fast 전략](#3-spring-boot-프로젝트-설정-및-fail-fast-전략)
    - [3.1 Gradle 의존성 설정](#31-gradle-의존성-설정)
    - [3.2 application.yml 설정](#32-applicationyml-설정)
  - [4. Producer 구현: 장애 대응 및 원자적 전송](#4-producer-구현-장애-대응-및-원자적-전송)
  - [5. Consumer 구현: 최소 한 번 보장 (At-least-once)](#5-consumer-구현-최소-한-번-보장-at-least-once)
    - [5.1 PEL 최대 재시도 초과 시 Dead Letter 처리](#51-pel-최대-재시도-초과-시-dead-letter-처리)
  - [6. 운영 용량 설계 및 Retention 가이드 (4KB, 50 TPS 기준)](#6-운영-용량-설계-및-retention-가이드-4kb-50-tps-기준)
    - [6.1 Stream MAXLEN 계산](#61-stream-maxlen-계산)
    - [6.2 MAXLEN 트리밍 동작](#62-maxlen-트리밍-동작)
    - [6.3 retryQueue 용량 계산 (Kafka buffer.memory 대응)](#63-retryqueue-용량-계산-kafka-buffermemory-대응)
  - [7. Helm 배포 및 환경 변수 매핑 가이드](#7-helm-배포-및-환경-변수-매핑-가이드)
  - [8. 고급 주제: 멱등성 및 Graceful Shutdown](#8-고급-주제-멱등성-및-graceful-shutdown)
    - [8.1 멱등성 (중복 처리 방지)](#81-멱등성-중복-처리-방지)
    - [8.2 Graceful Shutdown](#82-graceful-shutdown)
  - [9. 기능 검증 테스트 (redis-cli)](#9-기능-검증-테스트-redis-cli)
  - [10. 장애 시나리오 테스트](#10-장애-시나리오-테스트)
    - [10.1 Master Failover 테스트](#101-master-failover-테스트)
    - [10.2 retryQueue 포화 테스트](#102-retryqueue-포화-테스트)
    - [10.3 PEL 재처리 테스트 (Consumer 장애)](#103-pel-재처리-테스트-consumer-장애)
  - [11. 스트레스 테스트 결과 (실측)](#11-스트레스-테스트-결과-실측)
    - [11.1 테스트 방법](#111-테스트-방법)
    - [11.2 실측 결과](#112-실측-결과)
  - [12. 검증 체크리스트](#12-검증-체크리스트)

---

## 1. 인프라 구조 및 장애 조치 (HA)

Redis Stream은 **Sentinel** 체계를 통해 Kafka 클러스터와 유사한 고가용성을 제공합니다.

### 1.1 HA 구성 아키텍처

- **구조:** 3 Redis (1 Master, 2 Slaves) + 3 Sentinel
- **Failover:** Master 장애 시 Sentinel이 **약 5.8초(실측)** 내에 새 Master를 선출합니다.
- **연결 전략:** 앱은 Sentinel 주소만 알면 되며, `Lettuce` 라이브러리가 자동 전환을 처리합니다.

```text
+--------------------------------------------------+
|  Application (Spring Boot)                       |
|  [ Lettuce - Sentinel-aware client ]             |
+------------------------+-------------------------+
                         | connect via Sentinel addr
             +-----------v-----------+
             |    Sentinel Cluster   |
             |  [S1]  [S2]  [S3]     |
             |  quorum: 2/3 vote     |
             +-----------+-----------+
                         | return / update Master addr
             +-----------v-------------------------------+
             |  Redis Nodes                              |
             |  [Master] --async replication--> [Slave1] |
             |  (XADD / WAIT)                   [Slave2] |
             +-------------------------------------------+
```

## 1.2 데이터 영속성 및 용량 관리 (Infra vs App)

Redis Stream의 데이터 보존은 **서버의 생존 설정(Helm)**과 **데이터의 유통기한 설정(App)** 두 가지 층위에서 완성됩니다.

### [Bowl: 인프라 설정] Redis 서버 영속성 (Helm Chart / redis.conf)

서버가 꺼졌을 때 데이터를 어떻게 파일로 남기고 복구할지에 대한 설정입니다. 주로 K8s `values.yaml`에 정의합니다.

#### 영속성 모드 비교 (RDB / AOF / Hybrid)

Redis는 세 가지 파일 쓰기(영속성) 방식을 지원합니다. **Redis Stream 서비스에는 Hybrid 방식을 권장합니다.**

| 모드 | 핵심 설정 | 재기동 복구 속도 | 최대 유실 범위 | 권장 용도 |
| :--- | :--- | :--- | :--- | :--- |
| **RDB (스냅샷)** | `appendonly no` + `save 3600 1 300 100 60 10000` | 빠름 | 최대 수 분 | 캐시, 유실 허용 가능 |
| **AOF (명령 로그)** | `appendonly yes` + `aof-use-rdb-preamble no` | 느림 (전체 명령 순차 재실행) | 최대 1초 | 데이터 신뢰성이 중요한 경우 |
| **Hybrid (권장)** | `appendonly yes` + `aof-use-rdb-preamble yes` | 빠름 (RDB 스냅샷 + AOF 후미만 재실행) | 최대 1초 | **Redis Stream 서비스** |

> **Hybrid 동작 원리**: AOF Rewrite 시 파일 앞부분에 RDB 스냅샷을 기록하고, 그 이후 변경 사항만 AOF 형식으로 추가합니다.
> 재기동 시 전체 명령을 순차 재실행하는 순수 AOF 대비 10배 이상 빠른 복구가 가능하면서, RDB 단독 대비 데이터 유실 범위(최대 1초)를 최소화합니다.

#### 영속성 설정 항목

영속성 관련 설정은 두 계층으로 나뉩니다.

**[하드코딩] `charts/redis-sentinel/templates/configmap-redis.yaml` — 변경 불필요**

| 설정 항목 | 고정 값 | 상세 설명 |
| :--- | :--- | :--- |
| **AOF 활성화** | `appendonly yes` | 모든 쓰기 명령을 순서대로 기록합니다. Hybrid 모드의 전제 조건입니다. |
| **동기화 주기** | `appendfsync everysec` | 1초 단위 디스크 저장. 성능과 유실 최소화(최대 1초)의 균형입니다. |
| **Hybrid 모드 활성화** | `aof-use-rdb-preamble yes` | AOF 파일 앞부분에 RDB 스냅샷을 삽입하여 재기동 복구 속도를 10배 이상 높입니다. |
| **RDB 스냅샷 비활성화** | `save ""` | Hybrid 모드에서 AOF가 RDB 스냅샷을 포함하므로 별도 RDB는 비활성화합니다. |

**[오버라이드 가능] `values.yaml → redis.config` — 환경에 따라 조정**

| 설정 항목 | 권장 값 | 상세 설명 |
| :--- | :--- | :--- |
| **메모리 정책** | `maxmemoryPolicy: noeviction` | 메모리 부족 시 데이터를 강제로 지우지 않고 에러를 반환합니다. |
| **I/O 충돌 방지** | `noAppendfsyncOnRewrite: "yes"` | AOF Rewrite 진행 중 fsync를 유예하여 병목을 방지합니다. |
| **자동 Rewrite 비율** | `autoAofRewritePercentage: "100"` | 파일 크기가 직전 Rewrite 이후 100% 증가하면 자동으로 Rewrite를 실행합니다. 미설정 시 AOF 파일이 무한 증가합니다. |
| **자동 Rewrite 최소 크기** | `autoAofRewriteMinSize: "64mb"` | 이 크기 이상일 때만 Rewrite를 허용합니다. 소용량 파일의 빈번한 Rewrite를 방지합니다. |

---

### [Food: 앱 설정] 스트림 데이터 제어 (Spring Boot / Java)

메모리가 무한하지 않기에, 개발자는 스트림에 데이터가 얼마나 머물지 코드로 결정해야 합니다.

#### 1.2.5 데이터 제거 전략 (Retention)

Redis 서버는 스스로 데이터를 지우지 않습니다. **프로듀서(보내는 쪽)**가 데이터를 넣을 때마다 "여기까지만 남겨줘"라고 명령해야 합니다.

```java
// Producer 코드 예시
connection.streamCommands().xAdd(
    MapRecord.create(streamKey, message),
    // [권장] 약 60만 건 유지 (~ 옵션으로 CPU 부하 최소화)
    RedisStreamCommands.XAddOptions.maxlen(600000L).approximate() 
);
```

- **방식 A (갯수 제한):** `MAXLEN ~ 600000`을 통해 메모리 점유량을 예측 가능한 범위(예: 2.4GB) 내로 유지합니다.
- **방식 B (시간 제한):** `MINID`를 사용하여 "7일 전 데이터 삭제"와 같은 정책을 구현할 수 있으나, 보통 큐는 갯수 제한이 더 직관적입니다.

---

### 1.3 물리적 인프라 요구사항 (K8s & Storage)

설정값이 아무리 좋아도 밑바닥(Disk)이 느리면 Redis는 멈춥니다.

- **Storage Class (SSD 필수)**: AOF의 지속적인 쓰기 부하를 견디기 위해 **반드시 SSD 기반 스토리지(gp3, Premium SSD 등)**를 PV로 할당해야 합니다. HDD 사용 시 `fsync` 지연으로 인해 전체 시스템이 먹통이 될 수 있습니다.
- **PV 생명주기**: Pod가 재시작되거나 노드가 바뀌어도 `/data` 경로가 유지되도록 **PersistentVolumeClaim(PVC)**이 정확히 바인딩되어야 합니다.

---

### 💡 운영자 체크리스트 (Summary)

1. **개발자**: 프로듀서 코드에 `maxlen().approximate()`가 적용되어 있는가? (메모리 폭주 방지)
2. **인프라 담당자**: Helm 설정에 `appendonly yes`와 `everysec`이 들어가 있는가? (유실 방지)
3. **공통**: 현재 할당된 PV가 SSD 타입이며, 용량이 메모리 크기의 최소 2배 이상 확보되었는가? (Rewrite 공간 확보)

> **Candor**: "Redis는 무조건 안전하다"는 말은 거짓말입니다. 위 설정들을 다 해도 **디스크가 꽉 차거나(Disk Full)** **1초 이내에 서버가 두 번 죽으면** 데이터는 유실될 수 있습니다. 그래서 **프로듀서의 리트라이 큐** 도 필요한 것입니다.

---

## 2. Kafka vs Redis Stream 핵심 개념 매핑

| Kafka 개념 | Redis Stream 대응 | 상세 설명 |
| :--- | :--- | :--- |
| **Topic** | **Stream Key** | 메시지가 저장되는 물리적 키 |
| **Partition** | **멀티 스트림 키** | 물리적 파티션은 없으나, 키 분할로 확장 가능 (2.2절 참조) |
| **acks=all** | **WAIT 1 3000** | Master 쓰기 후 최소 1대의 Slave 복제 확인 (동기) |
| **buffer.memory** | **retryQueue (App)** | **[필수]** Redis 장애 시 앱 메모리에 쌓아두는 로컬 큐 |
| **Consumer Group** | **Consumer Group** | 여러 Consumer가 메시지를 분산 처리 |
| **Offset Commit** | **XACK** | 처리 완료된 메시지를 명시적으로 승인 |

### 2.1 파티션 및 확장 전략 (Partitioning Strategy)

Redis Stream은 **물리적 파티션을 지원하지 않습니다.** Kafka의 파티션과 같은 확장이 필요한 경우 아래 두 전략으로 우회합니다.

#### 전략 1: Consumer Group 확장 (Scale-out) — 대부분의 경우 권장

하나의 스트림 키에 여러 Consumer가 붙어 메시지를 분산 처리하는 방식입니다. XREADGROUP이 각 Consumer에게 중복 없이 메시지를 배분합니다.

```java
// Consumer Group 최초 생성 (앱 기동 시 1회, 이미 존재하면 예외 무시)
try {
    redisTemplate.opsForStream()
        .createGroup("strato-event", ReadOffset.from("0"), "my-group");
} catch (RedisSystemException e) {
    if (e.getCause() != null && e.getCause().getMessage().contains("BUSYGROUP")) {
        log.info("Consumer Group 이미 존재 — 생성 생략");
    } else {
        throw e;
    }
}
```

Consumer를 수평 확장할 때는 **같은 그룹 이름**을 공유하도록 배포합니다. Redis는 한 메시지를 그룹 내 하나의 Consumer에만 전달하므로 자동 부하 분산이 이루어집니다.

#### 전략 2: 멀티 키 파티셔닝 — 초고속 쓰기(수천 TPS 이상) 필요 시

쓰기 처리량이 단일 스트림 키의 한계를 초과하는 경우, `events:0` ~ `events:N` 형태로 키를 분리하고 Producer에서 해싱으로 라우팅합니다.

```java
// Producer — 해싱 기반 파티션 키 선택
private static final int PARTITION_COUNT = 4;  // 파티션 수 (2의 거듭제곱 권장)
private static final String BASE_KEY = "strato-event";

private String resolveStreamKey(String routingKey) {
    int partition = Math.abs(routingKey.hashCode()) % PARTITION_COUNT;
    return BASE_KEY + ":" + partition;
    // 결과: "strato-event:0", "strato-event:1", ...
}

public void sendMessage(String routingKey, String value) {
    String streamKey = resolveStreamKey(routingKey);
    // streamKey 로 XADD 수행 (기존 sendMessage 로직 재사용)
}
```

```java
// Consumer — 파티션 키별 별도 StreamMessageListenerContainer 등록
for (int i = 0; i < PARTITION_COUNT; i++) {
    String streamKey = BASE_KEY + ":" + i;
    // Consumer Group 생성 후 리스너 등록
    container.receive(
        Consumer.from("my-group", "consumer-" + instanceId + "-" + i),
        StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
        this::onMessage
    );
}
```

> **순서 보장 주의**: 멀티 키 파티셔닝 적용 시, 메시지 순서는 **동일 파티션 키(스트림 키) 내에서만** 보장됩니다.
> 동일 사용자/엔티티의 이벤트 순서가 중요하다면, 해당 식별자(예: `userId`)를 `routingKey`로 사용하여 항상 같은 파티션으로 라우팅되도록 하십시오.
> 파티션 간 전역 순서는 보장되지 않으며, 이는 Kafka 파티션과 동일한 제약입니다.

---

## 3. Spring Boot 프로젝트 설정 및 Fail-fast 전략

Sentinel Failover 기간(약 6초) 동안 앱 스레드가 블로킹되는 것을 방지하기 위해 **Fail-fast(빠른 실패)** 설정을 권장합니다.

### 3.1 Gradle 의존성 설정

**전환 전 (Kafka)**

```groovy
dependencies {
    implementation 'org.springframework.kafka:spring-kafka'
    compileOnly 'org.projectlombok:lombok'
    annotationProcessor 'org.projectlombok:lombok'
}
```

**전환 후 (Redis Stream)**

```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-data-redis'
    compileOnly 'org.projectlombok:lombok'
    annotationProcessor 'org.projectlombok:lombok'
}
```

> `spring-kafka` 의존성을 완전히 제거합니다. `spring-boot-starter-data-redis`는 Lettuce 클라이언트를 포함합니다.

### 3.2 application.yml 설정

**전환 전 (Kafka)**

```yaml
spring:
  kafka:
    bootstrap-servers: kafka-broker:9092
    producer:
      acks: all
      retries: 3
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.apache.kafka.common.serialization.StringSerializer
    consumer:
      group-id: my-group
      auto-offset-reset: earliest
      enable-auto-commit: false
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
```

**전환 후 (Redis Stream)**

```yaml
spring:
  data:
    redis:
      sentinel:
        master: mymaster
        nodes: ${SPRING_REDIS_SENTINEL_NODES:redis-sentinel.strato-product.svc:26379}
      password: "${REDIS_PASSWORD}"
      timeout: 1000ms      # [Fail-fast] Sentinel Failover 중 블로킹 방지
      connect-timeout: 2000ms
```

> Kafka의 `acks: all` + `retries: 3` 역할은 Redis Stream에서 `WAIT 1 3000` 명령(Slave 복제 확인)과 앱 레벨 `retryQueue`가 대신합니다.

---

## 4. Producer 구현: 장애 대응 및 원자적 전송

**전환 전 (Kafka)**

```java
@Service
public class KafkaEventProducer {
    @Autowired private KafkaTemplate<String, String> kafkaTemplate;

    public void sendMessage(String key, String value) {
        // Kafka는 내부 버퍼(buffer.memory)와 재시도(retries)를 자체 처리
        kafkaTemplate.send("strato-event", key, value)
            .addCallback(
                result -> log.info("전송 성공: offset={}", result.getRecordMetadata().offset()),
                ex    -> log.error("전송 실패: {}", ex.getMessage())
            );
    }
}
```

**전환 후 (Redis Stream)**

Redis는 내장 버퍼가 없으므로 앱 메모리에 **로컬 재시도 큐(`retryQueue`)**를 직접 구현해야 합니다.

```java
@Service
public class RedisStreamProducer {
    @Autowired private StringRedisTemplate redisTemplate;
    private BlockingQueue<Map.Entry<String, String>> retryQueue = new LinkedBlockingQueue<>(100000);

    public void sendMessage(String key, String value) {
        try {
            executeRedisCommands(key, value);
        } catch (Exception e) {
            retryQueue.offer(new AbstractMap.SimpleEntry<>(key, value));
            log.warn("Redis 장애로 로컬 큐 적재: {}", key);
        }
    }

    private void executeRedisCommands(String key, String value) {
        redisTemplate.execute((RedisCallback<Void>) connection -> {
            byte[] streamKey = "strato-event".getBytes(StandardCharsets.UTF_8);
            connection.streamCommands().xAdd(
                MapRecord.create(streamKey, Map.of(key.getBytes(), value.getBytes())),
                RedisStreamCommands.XAddOptions.maxlen(600000L).approximate()  // ~ 옵션: CPU 부하 최소화
            );
            connection.execute("WAIT", "1".getBytes(), "3000".getBytes());
            return null;
        });
    }

    @Scheduled(fixedDelay = 5000)
    public void flushRetryBuffer() {
        while (!retryQueue.isEmpty()) {
            Map.Entry<String, String> msg = retryQueue.peek();
            try {
                executeRedisCommands(msg.getKey(), msg.getValue());
                retryQueue.poll();
            } catch (Exception e) { break; }
        }
    }
}
```

---

## 5. Consumer 구현: 최소 한 번 보장 (At-least-once)

**전환 전 (Kafka)**

```java
@Service
public class KafkaEventConsumer {

    @KafkaListener(topics = "strato-event", groupId = "my-group")
    public void consume(ConsumerRecord<String, String> record,
                        Acknowledgment ack) {
        try {
            process(record.value());
            ack.acknowledge();  // 수동 커밋 (At-least-once)
        } catch (Exception e) {
            log.error("처리 실패: offset={}", record.offset());
            // 재처리는 Kafka가 오프셋 미커밋으로 자동 재전달
        }
    }
}
```

**전환 후 (Redis Stream)**

Kafka의 오프셋 커밋 역할을 `XACK`가 담당합니다. 처리 성공 시에만 XACK를 호출하여 At-least-once를 보장합니다.
미승인 메시지는 PEL(Pending Entry List)에 남아 재처리 대상이 됩니다.

```java
@Service
public class RedisStreamConsumer implements StreamListener<String, MapRecord<String, String, String>> {
    @Override
    public void onMessage(MapRecord<String, String, String> message) {
        try {
            process(message.getValue().get("data"));
            // 성공 시에만 XACK (At-least-once)
            redisTemplate.opsForStream().acknowledge("strato-event", "my-group", message.getId());
        } catch (Exception e) {
            log.error("처리 실패, PEL 잔류: {}", message.getId());
        }
    }
}
```

### 5.1 PEL 최대 재시도 초과 시 Dead Letter 처리

처리를 계속 실패하는 메시지가 PEL에 무한히 쌓이면 메모리 누수와 모니터링 오염이 발생합니다.
**N회 재시도 초과 시 Dead Letter Stream으로 이동하고 PEL에서 제거**합니다.

```java
@Service
public class PelReprocessor {

    @Autowired private StringRedisTemplate redisTemplate;

    private static final String STREAM_KEY    = "strato-event";
    private static final String GROUP_NAME    = "my-group";
    private static final String DLQ_KEY       = "strato-event:dead-letter";
    private static final int    MAX_RETRY     = 3;       // N회 초과 시 DLQ 이동
    private static final long   IDLE_MS       = 60_000L; // 60초 이상 미처리된 메시지만 대상

    // 1분마다 PEL 스캔 — idle 상태 메시지 재처리 or DLQ 이동
    @Scheduled(fixedDelay = 60_000)
    public void reclaimStalePendingMessages() {
        PendingMessages pending = redisTemplate.opsForStream()
            .pending(STREAM_KEY, Consumer.from(GROUP_NAME, "reprocessor"),
                     Range.unbounded(), 100);

        if (pending == null || pending.isEmpty()) return;

        for (PendingMessage msg : pending) {
            long deliveryCount = msg.getTotalDeliveryCount();
            long idleMs        = msg.getElapsedTimeSinceLastDelivery().toMillis();

            if (idleMs < IDLE_MS) continue;  // 아직 활성 처리 중인 메시지는 건너뜀

            if (deliveryCount > MAX_RETRY) {
                // ── Dead Letter 처리 ──────────────────────────────
                log.error("[DLQ] 최대 재시도({}) 초과 — messageId={}, 재시도 횟수={}",
                          MAX_RETRY, msg.getId(), deliveryCount);

                // Dead Letter Stream에 원본 ID와 실패 정보 기록
                redisTemplate.opsForStream().add(
                    DLQ_KEY,
                    Map.of(
                        "originalId",    msg.getId().getValue(),
                        "deliveryCount", String.valueOf(deliveryCount),
                        "failedAt",      String.valueOf(System.currentTimeMillis())
                    )
                );

                // PEL에서 제거 (XACK)
                redisTemplate.opsForStream()
                    .acknowledge(STREAM_KEY, GROUP_NAME, msg.getId());

            } else {
                // ── 재처리 시도 (XAUTOCLAIM) ─────────────────────
                // idle 메시지를 현재 Consumer에게 재할당
                redisTemplate.opsForStream().claim(
                    STREAM_KEY, Consumer.from(GROUP_NAME, "reprocessor"),
                    Duration.ofMillis(IDLE_MS),
                    msg.getId()
                );
                log.warn("[PEL] 재처리 시도 — messageId={}, 시도 횟수={}",
                         msg.getId(), deliveryCount);
            }
        }
    }
}
```

**Dead Letter Stream 모니터링**

```bash
# DLQ에 쌓인 실패 메시지 확인
redis-cli -a ${REDIS_PASSWORD} XRANGE strato-event:dead-letter - + COUNT 10

# DLQ 건수 확인
redis-cli -a ${REDIS_PASSWORD} XLEN strato-event:dead-letter

# 현재 PEL 전체 현황 (그룹 전체)
redis-cli -a ${REDIS_PASSWORD} XPENDING strato-event my-group - + 100
```

> **DLQ 처리 정책**: Dead Letter에 쌓인 메시지는 별도 알림(Slack, 모니터링)을 통해 수동 확인하거나,
> 별도 배치 프로세스로 재처리합니다. DLQ 자체도 MAXLEN으로 크기를 제한하는 것을 권장합니다.

---

## 6. 운영 용량 설계 및 Retention 가이드 (4KB, 50 TPS 기준)

### 6.1 Stream MAXLEN 계산

**기본 계산식**

```
보존 기간(초) = MAXLEN ÷ TPS
MAXLEN = 보존 기간(초) × TPS
```

| 보존 목표 | 계산 | MAXLEN | Redis 메모리 (4KB 기준) |
| :--- | :--- | :--- | :--- |
| 1시간 | 3,600s × 50 TPS | 180,000 | ~720MB |
| **3시간 (권장)** | **10,800s × 50 TPS** | **600,000** | **~2.4GB** |
| 6시간 | 21,600s × 50 TPS | 1,080,000 | ~4.3GB |

> **권장 MAXLEN: 600,000건** — Consumer 장애 시 최대 3시간 분량을 PEL에 보존하면서 재처리 여유를 확보합니다.
> `maxmemory`는 Stream 메모리(2.4GB) + 기타 오버헤드를 고려해 **3GB 이상** 설정합니다.

### 6.2 MAXLEN 트리밍 동작

MAXLEN 트리밍은 **주기 스케줄러가 아닌 `XADD` 호출 시점에만 실행**됩니다.

```
XADD 호출 → 메시지 추가 → 현재 길이 > MAXLEN 이면 오래된 항목 제거
```

| 옵션 | 명령 | 동작 | CPU 부하 |
| :--- | :--- | :--- | :--- |
| **Approximate (권장)** | `MAXLEN ~ 600000` | 내부 노드 단위로 정리, 정확한 N은 아님 | 낮음 |
| Exact | `MAXLEN 600000` | 매 XADD마다 정확히 N건 유지 | 높음 |

> `XADD`가 없으면 트리밍도 없습니다. Consumer만 있고 Producer가 멈춘 상태에서는 PEL이 계속 쌓일 수 있습니다.

### 6.3 retryQueue 용량 계산 (Kafka buffer.memory 대응)

Kafka의 `buffer.memory`(프로듀서 내장 버퍼)에 해당하는 것이 Redis Stream에서는 앱 레벨 `retryQueue`입니다.

**Kafka 설정 대응표**

| Kafka 설정 | 기본값 | Redis Stream 대응 |
| :--- | :--- | :--- |
| `buffer.memory` | 32MB | `LinkedBlockingQueue<>(N)` capacity |
| `max.block.ms` | 60,000ms | capacity 초과 시 즉시 드롭 (`offer()` = false) |
| `retries` | 2,147,483,647 | `flushRetryBuffer()` 무한 재시도 |
| `retry.backoff.ms` | 100ms | `@Scheduled(fixedDelay = 5000)` |

**retryQueue capacity 계산식**

```
capacity = TPS × 예상 최대 장애 지속 시간(초) × 안전 여유(2배)
```

| 시나리오 | 계산 | capacity | 앱 메모리 점유 (4KB) |
| :--- | :--- | :--- | :--- |
| Sentinel Failover (6초) | 50 × 6 × 2 | 600 | ~2.4MB |
| 네트워크 순단 (2분) | 50 × 120 × 2 | 12,000 | ~48MB |
| **장기 장애 (33분, 현재 설정)** | **50 × 2000 × 1** | **100,000** | **~400MB** |

> **현재 100,000건 설정은 50 TPS 기준 약 33분 분량의 버퍼**입니다. 앱 메모리 한계를 초과하지 않는 범위에서 환경에 맞게 조정하세요.

```java
// capacity를 환경 변수로 외부 주입 가능하도록 구성
@Value("${redis.stream.retry-queue-capacity:100000}")
private int retryQueueCapacity;

@PostConstruct
public void init() {
    this.retryQueue = new LinkedBlockingQueue<>(retryQueueCapacity);
}
```

```yaml
# application.yml
redis:
  stream:
    retry-queue-capacity: 100000  # TPS × 예상 장애 시간(초) × 여유배수
```

---

## 7. Helm 배포 및 환경 변수 매핑 가이드

애플리케이션 종료 시 큐를 비울 충분한 시간을 확보해야 합니다.

```yaml
spec:
  terminationGracePeriodSeconds: 60  # [중요] 큐 비우기 시간 확보
  template:
    spec:
      containers:
      - name: my-app
        env:
        - name: SPRING_REDIS_SENTINEL_NODES
          value: "redis-sentinel.strato-product.svc:26379"
```

---

## 8. 고급 주제: 멱등성 및 Graceful Shutdown

### 8.1 멱등성 (중복 처리 방지)

At-least-once 보장 구조에서 Consumer 재시작 또는 PEL 재처리 시 동일 메시지가 두 번 처리될 수 있습니다.
Redis `SETNX`로 메시지 ID를 24시간 보관하여 중복을 차단합니다.

```java
@Service
public class RedisStreamConsumer implements StreamListener<String, MapRecord<String, String, String>> {
    @Autowired private StringRedisTemplate redisTemplate;

    private boolean isAlreadyProcessed(String messageId) {
        // SETNX: 키가 없으면 세팅(true 반환), 이미 있으면 false 반환
        Boolean inserted = redisTemplate.opsForValue()
            .setIfAbsent("processed:" + messageId, "1", Duration.ofHours(24));
        return Boolean.FALSE.equals(inserted);  // false → 이미 존재 → 중복
    }

    @Override
    public void onMessage(MapRecord<String, String, String> message) {
        String messageId = message.getId().getValue();

        if (isAlreadyProcessed(messageId)) {
            log.warn("중복 메시지 무시: {}", messageId);
            // 중복이어도 XACK는 해야 PEL에서 제거됨
            redisTemplate.opsForStream()
                .acknowledge("strato-event", "my-group", message.getId());
            return;
        }

        try {
            process(message.getValue().get("data"));
            redisTemplate.opsForStream()
                .acknowledge("strato-event", "my-group", message.getId());
        } catch (Exception e) {
            log.error("처리 실패, PEL 잔류: {}", messageId);
        }
    }
}
```

> **주의**: `processed:*` 키가 Redis 메모리를 잠식하지 않도록 TTL(24시간)을 반드시 설정합니다.
> 처리량이 매우 높다면 DB의 `UNIQUE INDEX`를 대신 사용하는 것이 더 안전합니다.

### 8.2 Graceful Shutdown

Pod 종료 시 `retryQueue`에 남은 메시지를 최대한 전송하고 종료합니다.
`terminationGracePeriodSeconds: 60`과 짝을 이루어야 효과가 있습니다.

```java
@PreDestroy
public void onShutdown() {
    log.info("Graceful Shutdown 시작 — retryQueue 잔량: {}건", retryQueue.size());
    long deadline = System.currentTimeMillis() + 30_000L;  // 최대 30초 시도

    while (!retryQueue.isEmpty() && System.currentTimeMillis() < deadline) {
        Map.Entry<String, String> msg = retryQueue.peek();
        try {
            executeRedisCommands(msg.getKey(), msg.getValue());
            retryQueue.poll();
        } catch (Exception e) {
            log.warn("Shutdown 중 Redis 전송 실패 — {}건 잔류, 0.5초 후 재시도", retryQueue.size());
            try {
                Thread.sleep(500);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                break;
            }
        }
    }

    if (!retryQueue.isEmpty()) {
        log.error("Shutdown 완료 — {}건 미전송 (데이터 유실 가능성)", retryQueue.size());
    } else {
        log.info("Shutdown 완료 — retryQueue 정상 소진");
    }
}
```

---

## 9. 기능 검증 테스트 (redis-cli)

```bash
# PEL(미승인 메시지) 확인
redis-cli -a ${REDIS_PASSWORD} XPENDING strato-event my-group - + 10
# 수동 메시지 발송
redis-cli -a ${REDIS_PASSWORD} XADD strato-event MAXLEN ~ 600000 '*' data '{"test":"hello"}'
```

---

## 10. 장애 시나리오 테스트

### 10.1 Master Failover 테스트

```bash
NAMESPACE="redis-stream-official"

# 1. 현재 Master 노드 확인
kubectl exec -it redis-node-0 -n ${NAMESPACE} -- \
  redis-cli -a ${REDIS_PASSWORD} --no-auth-warning INFO replication \
  | grep -E "role|master_host|connected_slaves"

# 2. 앱에서 메시지 지속 발송 중인 상태에서 Master Pod 강제 삭제
MASTER_POD=$(kubectl get pods -n ${NAMESPACE} -l role=master -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod ${MASTER_POD} -n ${NAMESPACE}

# 3. Sentinel이 새 Master를 선출하는 과정 실시간 모니터링 (약 5~6초 소요)
kubectl get pods -n ${NAMESPACE} -w

# 4. Failover 완료 후 새 Master 확인
kubectl exec -it redis-node-0 -n ${NAMESPACE} -- \
  redis-cli -a ${REDIS_PASSWORD} --no-auth-warning INFO replication \
  | grep -E "role|master_host"

# 5. Failover 기간 동안 앱 retryQueue 동작 여부 확인
kubectl logs <app-pod-name> --since=2m | grep -E "로컬 큐 적재|retryQueue|flush"
```

**기대 결과**: Failover 완료 후 retryQueue에 적재된 메시지가 자동으로 재전송되고,
전체 유실 건수 0을 확인합니다.

### 10.2 retryQueue 포화 테스트

```bash
# 1. Redis를 일시 중단하여 연결 불가 상태 만들기
kubectl exec -it redis-node-0 -n ${NAMESPACE} -- \
  redis-cli -a ${REDIS_PASSWORD} --no-auth-warning DEBUG SLEEP 60

# 2. 앱 로그에서 retryQueue 적재 확인
kubectl logs <app-pod-name> -f | grep -E "로컬 큐 적재|offer"

# 3. capacity(100,000건) 초과 시 드롭 로그 확인
# offer() 반환값이 false이면 드롭 → 별도 에러 로그 필요 여부 검토

# 4. Redis 복구 후 자동 flush 확인 (5초 이내)
kubectl logs <app-pod-name> --since=2m | grep "flush\|flushRetryBuffer"
```

**기대 결과**: capacity 초과분은 드롭되고 에러 로그가 출력됩니다.
Redis 복구 후 `flushRetryBuffer`가 5초 내에 자동 실행됩니다.

### 10.3 PEL 재처리 테스트 (Consumer 장애)

```bash
# 1. PEL에 미승인 메시지가 있는지 확인
redis-cli -a ${REDIS_PASSWORD} XPENDING strato-event my-group - + 10

# 2. 특정 Consumer의 미승인 메시지를 다른 Consumer가 재처리하도록 claim
# idle-time: 60000ms(1분) 이상 미처리된 메시지 강제 이관
redis-cli -a ${REDIS_PASSWORD} XAUTOCLAIM strato-event my-group \
  consumer-new 60000 0-0 COUNT 10

# 3. 재처리 후 PEL 소진 확인
redis-cli -a ${REDIS_PASSWORD} XPENDING strato-event my-group - + 10
```

---

## 11. 스트레스 테스트 결과 (실측)

### 11.1 테스트 방법

```bash
# 방법 A: redis-cli 루프 (간단, 단일 클라이언트)
# 1,000건 연속 발송 후 Stream 길이 확인
for i in $(seq 1 1000); do
  redis-cli -a ${REDIS_PASSWORD} --no-auth-warning \
    XADD strato-event MAXLEN "~" 600000 "*" \
    data "{\"id\":${i},\"ts\":$(date +%s%3N)}" > /dev/null
done
redis-cli -a ${REDIS_PASSWORD} --no-auth-warning XLEN strato-event

# 방법 B: 병렬 발송 (TPS 부하 시뮬레이션)
# 50개 백그라운드 프로세스로 각 200건 = 총 10,000건
for i in $(seq 1 50); do
  (for j in $(seq 1 200); do
    redis-cli -a ${REDIS_PASSWORD} --no-auth-warning \
      XADD strato-event MAXLEN "~" 600000 "*" \
      data "{\"worker\":${i},\"seq\":${j}}" > /dev/null
  done) &
done
wait
echo "총 메시지 수: $(redis-cli -a ${REDIS_PASSWORD} --no-auth-warning XLEN strato-event)"

# 방법 C: WAIT 명령 지연 측정
time redis-cli -a ${REDIS_PASSWORD} --no-auth-warning \
  XADD strato-event "*" data "wait-test" \; \
  WAIT 1 3000
```

### 11.2 실측 결과

| 시나리오 | TPS | 유실 건수 | 평균 처리 지연 | `WAIT` 응답 시간 |
| :--- | :--- | :--- | :--- | :--- |
| 정상 부하 | 50 TPS | 0건 | 1ms 내외 | ~2ms |
| 피크 부하 | 300 TPS | 0건 | 3~8ms | 최대 120ms |
| Failover 발생 시 | 50 TPS | 0건 (retryQueue 처리) | Failover 중 적재 후 복구 | N/A |

> **WAIT 지연 원인**: 300 TPS 환경에서 Slave 복제 I/O가 Master 쓰기 속도를 따라가지 못할 때 `WAIT 1 3000` 명령의 응답 시간이 증가합니다. `WAIT` 타임아웃(3000ms)에 도달하면 예외가 발생하고 `retryQueue`에 적재됩니다.

---

## 12. 검증 체크리스트

- [x] Consumer Group 자동 생성 및 메시지 수신 확인
- [x] 장애 시 로컬 버퍼링 및 복구 후 자동 플러시 확인
- [x] AOF 파일 저장 및 PV 보존 상태 확인
- [x] terminationGracePeriodSeconds 설정 확인 (60s 권장)

---
*본 가이드는 실제 mq-test 환경에서의 실측 데이터를 기반으로 작성되었습니다.*
