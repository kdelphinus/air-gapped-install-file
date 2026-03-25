package com.example.redisstream.producer;

import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentLinkedQueue;

@Service
public class RedisStreamProducer {

    private final StringRedisTemplate redisTemplate;
    private final ConcurrentLinkedQueue<Map<String, String>> localBuffer = new ConcurrentLinkedQueue<>();
    private static final String STREAM_KEY = "mystream";
    private static final long MAXLEN = 100000L;   // OOM 방지 필수
    private static final int  WAIT_REPLICAS = 1;  // at-least-once: 최소 1개 replica 동기 복제
    private static final long WAIT_TIMEOUT_MS = 5000L;

    public RedisStreamProducer(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    public void sendMessage(String key, String value) {
        Map<String, String> message = Collections.singletonMap(key, value);
        try {
            // 1. XADD — OOM 방지: 메시지 추가 후 trim으로 MAXLEN 강제
            // StringRedisTemplate.opsForStream() → StreamOperations<String, Object, Object>
            Map<Object, Object> body = new LinkedHashMap<>();
            body.put(key, value);
            MapRecord<String, Object, Object> record = MapRecord.create(STREAM_KEY, body);
            RecordId recordId = redisTemplate.opsForStream().add(record);
            redisTemplate.opsForStream().trim(STREAM_KEY, MAXLEN);  // approximate trim
            System.out.println("Message sent with ID: " + recordId);

            // 2. WAIT — 최소 1개 replica에 동기 복제 확인 (at-least-once producer 보장)
            // RedisConnection.execute()로 raw WAIT 명령 실행
            Long replicas = redisTemplate.execute((RedisCallback<Long>) conn -> {
                Object result = conn.execute("WAIT",
                    String.valueOf(WAIT_REPLICAS).getBytes(StandardCharsets.UTF_8),
                    String.valueOf(WAIT_TIMEOUT_MS).getBytes(StandardCharsets.UTF_8));
                return result instanceof Long ? (Long) result : 0L;
            });
            if (replicas == null || replicas < WAIT_REPLICAS) {
                System.err.printf("Replication not confirmed (replicas=%d), buffering locally...%n", replicas);
                localBuffer.offer(message);
            }
        } catch (Exception e) {
            System.err.println("Send failed, buffering locally: " + e.getMessage());
            localBuffer.offer(message); // 실패 시 로컬 버퍼에 저장하여 유실 방지
        }
    }

    // 버퍼에 쌓인 미전송 메시지를 주기적으로 재전송
    @Scheduled(fixedDelay = 5000)
    public void flushBuffer() {
        Map<String, String> msg;
        while ((msg = localBuffer.poll()) != null) {
            sendMessage(msg.keySet().iterator().next(), msg.values().iterator().next());
        }
    }
}
