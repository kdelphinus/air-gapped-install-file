package com.example.redisstream.consumer;

import org.springframework.data.domain.Range;
import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.PendingMessage;
import org.springframework.data.redis.connection.stream.PendingMessages;
import org.springframework.data.redis.connection.stream.PendingMessagesSummary;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.StreamRecords;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.stream.StreamListener;
import org.springframework.data.redis.stream.StreamMessageListenerContainer;
import org.springframework.data.redis.stream.Subscription;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import jakarta.annotation.PostConstruct;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@Service
public class RedisStreamConsumer implements StreamListener<String, MapRecord<String, String, String>> {

    private final StreamMessageListenerContainer<String, MapRecord<String, String, String>> listenerContainer;
    private final StringRedisTemplate redisTemplate;

    private static final String STREAM_KEY = "mystream";
    private static final String GROUP_NAME = "mygroup";
    private static final String CONSUMER_NAME = "consumer1";
    private static final Duration ZOMBIE_THRESHOLD = Duration.ofSeconds(30);

    public RedisStreamConsumer(StreamMessageListenerContainer<String, MapRecord<String, String, String>> listenerContainer,
                               StringRedisTemplate redisTemplate) {
        this.listenerContainer = listenerContainer;
        this.redisTemplate = redisTemplate;
    }

    @PostConstruct
    public void init() {
        try {
            redisTemplate.opsForStream().createGroup(STREAM_KEY, GROUP_NAME);
        } catch (Exception e) {
            // Group already exists — 멱등성 보장
        }

        listenerContainer.receive(
                Consumer.from(GROUP_NAME, CONSUMER_NAME),
                StreamOffset.create(STREAM_KEY, ReadOffset.lastConsumed()),
                this
        );
        listenerContainer.start();
    }

    @Override
    public void onMessage(MapRecord<String, String, String> message) {
        try {
            System.out.println("Received message: " + message.getValue());
            // 비즈니스 로직 처리...

            // 처리 성공 시에만 명시적 ACK (At-Least-Once Consumer)
            redisTemplate.opsForStream().acknowledge(GROUP_NAME, message);
            System.out.println("ACK sent for ID: " + message.getId());
        } catch (Exception e) {
            // ACK 미전송 → PEL에 남아 zombie recovery 대상이 됨
            System.err.println("Error processing message, will remain in pending list: " + e.getMessage());
        }
    }

    /**
     * Zombie 메시지 회수 (Kafka 자동 리밸런싱 대체 로직)
     *
     * Consumer 장애로 ZOMBIE_THRESHOLD 이상 ACK되지 않은 메시지를
     * XCLAIM으로 현재 consumer가 소유권을 획득하여 재처리합니다.
     *
     * Kafka: Group Coordinator가 자동으로 파티션 리밸런싱
     * Redis Streams: 앱 레벨에서 XPENDING + XCLAIM 직접 구현 필요
     */
    @Scheduled(fixedDelay = 30_000)
    public void autoClaimZombieMessages() {
        try {
            // 1. PEL 전체 요약 — pending 메시지가 없으면 즉시 반환
            PendingMessagesSummary summary =
                    redisTemplate.opsForStream().pending(STREAM_KEY, GROUP_NAME);
            if (summary == null || summary.getTotalPendingMessages() == 0) {
                return;
            }

            // 2. 오래된 pending 메시지 목록 조회 (모든 consumer, 최대 100개)
            PendingMessages pendingMessages = redisTemplate.opsForStream()
                    .pending(STREAM_KEY, GROUP_NAME, Range.unbounded(), 100L);

            for (PendingMessage pending : pendingMessages) {
                if (pending.getIdleTime().compareTo(ZOMBIE_THRESHOLD) < 0) {
                    continue; // 아직 threshold 미달
                }

                System.out.printf("Claiming zombie: id=%s, from=%s, idle=%ds%n",
                        pending.getId(), pending.getConsumerName(),
                        pending.getIdleTime().toSeconds());

                // 3. XCLAIM: 현재 consumer가 소유권 획득
                @SuppressWarnings("unchecked")
                List<MapRecord<String, Object, Object>> claimed =
                        redisTemplate.opsForStream().claim(
                                STREAM_KEY, GROUP_NAME, CONSUMER_NAME,
                                ZOMBIE_THRESHOLD, pending.getId());

                if (claimed == null) continue;

                // 4. 획득한 메시지 재처리 (String 타입으로 변환)
                for (MapRecord<String, Object, Object> record : claimed) {
                    Map<String, String> stringMap = record.getValue().entrySet().stream()
                            .collect(Collectors.toMap(
                                    e -> String.valueOf(e.getKey()),
                                    e -> String.valueOf(e.getValue())
                            ));
                    MapRecord<String, String, String> typed =
                            StreamRecords.newRecord()
                                    .ofStrings(stringMap)
                                    .withStreamKey(record.getStream())
                                    .withId(record.getId());
                    onMessage(typed);
                }
            }
        } catch (Exception e) {
            System.err.println("Zombie recovery error: " + e.getMessage());
        }
    }
}
