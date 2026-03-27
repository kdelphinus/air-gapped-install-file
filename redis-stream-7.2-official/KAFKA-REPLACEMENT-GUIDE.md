# Kafka to Redis Stream 변환 및 장애 대응 가이드

이 문서는 Kafka의 핵심 기능을 Redis Stream으로 대체하기 위한 기술 검증 결과와 구현 전략을 담고 있습니다.

## 1. 인프라 구성 (3대 HA)
- **구조:** 3 Redis (1 Master, 2 Slaves) + 3 Sentinel
- **장애 조치:** Sentinel이 Master 장애 감지 후 20초 이내에 Slave를 Master로 승격 (Quorum 2)
- **설정:** `values.yaml`에서 `redis.replicas: 3`, `sentinel.replicas: 3` 확인 완료.

## 2. Kafka 기능 매핑

| Kafka 개념 | Redis Stream 대응 | 설명 |
| :--- | :--- | :--- |
| Topic | Stream Key | `XADD mystream * field value` |
| Partition | (Single Stream) | Redis Stream은 단일 키 내에서 순서를 보장함. 처리량 분산은 Consumer Group으로 해결. |
| Offset | Stream ID (Entry ID) | `<milliseconds>-<sequence>` 형식 (예: 1711512345678-0) |
| Consumer Group | Consumer Group | `XGROUP CREATE mystream mygroup $ MKSTREAM` |
| Acknowledgement | `XACK` | 처리가 완료된 메시지만 PEL(Pending Entry List)에서 제거. |

## 3. "최소 한 번 보장(At-least-once)" 구현 (Spring Boot)

Consumer는 메시지를 읽은 후 처리가 성공했을 때만 `XACK`를 호출합니다.

```java
// Consumer Logic 예시
@Service
public class StreamConsumerService implements StreamListener<String, MapRecord<String, String, String>> {
    
    @Autowired
    private RedisTemplate<String, String> redisTemplate;

    @Override
    public void onMessage(MapRecord<String, String, String> message) {
        try {
            // 1. 비즈니스 로직 처리
            processMessage(message.getValue());

            // 2. 처리 성공 시 ACK 전송 (Kafka의 commitSync/Async 역할)
            redisTemplate.opsForStream().acknowledge("mystream", "mygroup", message.getId());
        } catch (Exception e) {
            // 에러 발생 시 ACK를 보내지 않음 -> 메시지는 PEL(Pending Entry List)에 남음
            log.error("메시지 처리 실패: " + message.getId(), e);
        }
    }
}
```

## 4. 네트워크 장애 및 "보내는 큐" 관리 전략 (Producer)

Kafka의 `buffer.memory` 및 `retries` 기능을 Redis Stream에서 구현하는 방법입니다.

### 4.1 Producer 재시도 및 버퍼링 (네트워크 장애 대응)
Redis 서버와의 일시적 단절 시 메시지를 보관했다가 전송하는 전략입니다.

```java
@Service
public class StreamProducerService {

    @Autowired
    private RedisTemplate<String, String> redisTemplate;
    
    // 로컬 재시도 큐 (메모리 내 임시 보관)
    private final BlockingQueue<ObjectRecord<String, MyData>> retryQueue = new LinkedBlockingQueue<>(10000);

    @Retryable(value = {RedisConnectionFailureException.class}, maxAttempts = 3, backoff = @Backoff(delay = 1000))
    public void sendMessage(MyData data) {
        try {
            // XADD 시 MAXLEN 옵션으로 큐 크기 상한 고정 (Kafka의 Retention 역할)
            // ~ 옵션은 정확한 크기 대신 근사치로 제한하여 성능 최적화
            redisTemplate.opsForStream().add(
                StreamRecords.newRecord()
                    .in("mystream")
                    .ofObject(data)
                    .withMaxLen(1000000L) // 최대 100만 건 유지 (초과 시 오래된 것 삭제)
            );
        } catch (RedisConnectionFailureException e) {
            // 재시도 실패 시 로컬 버퍼에 저장하거나 에러 처리
            retryQueue.offer(record);
            throw e;
        }
    }
}
```

### 4.2 최대 용량 및 시간 제어 (Retention)
- **최대 용량(MAXLEN):** `XADD mystream MAXLEN ~ 1000000 * field value`
    - 수정 방법: Producer 코드 내 `withMaxLen(N)` 값 수정 또는 `redis-cli`에서 직접 호출.
- **시간 기반(MINID):** 특정 시간 이전 데이터 삭제 (Redis 7.0+)
    - `XADD mystream MINID ~ <timestamp> * field value`
    - 예: 7일 이전 데이터 삭제 등.

## 5. Kafka 대비 장단점 및 변환 적합성
- **장점:** 매우 낮은 지연 시간(Low Latency), 인프라 운영 비용 저렴, 단순한 모델.
- **단점:** Kafka만큼의 거대한 Throughput(초당 수백만 건 이상) 및 디스크 기반 대용량 보관에는 한계가 있음.
- **결론:** 실시간 메시지 처리, 이벤트 기반 마이크로서비스 간 통신, 수백만 건 단위의 데이터 파이프라인에는 Kafka를 완벽히 대체 가능함.

## 6. 검증 완료 항목
- [x] **Helm 구성:** official 차트 기반 3대 HA 구성 확인.
- [x] **HA 테스트:** Sentinel Failover 정상 동작 확인.
- [x] **메시지 테스트:** `test-stream.sh`를 통한 송수신 검증 완료.
- [x] **At-least-once:** Spring Boot `XACK` 및 `XPENDING` 전략 수립.
- [x] **장애 대응:** Producer 측 Local Buffer 및 Retry 전략 수립.
- [x] **Retention:** `MAXLEN` 및 `MINID`를 통한 제어 기능 확인.
