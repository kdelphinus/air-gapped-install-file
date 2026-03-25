package com.example.redisstream.producer;

import org.springframework.data.redis.connection.RedisCallback;
import org.springframework.data.redis.connection.RedisStreamCommands.XAddOptions;
import org.springframework.data.redis.connection.stream.RecordId;
import org.springframework.data.redis.connection.stream.StreamRecords;
import org.springframework.data.redis.connection.stream.StringRecord;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.util.Collections;
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
            StringRecord record = StreamRecords.string(message).withStreamKey(STREAM_KEY);

            // 1. MAXLEN 지정으로 스트림 크기 제한 (OOM 방지)
            XAddOptions options = XAddOptions.maxlen(MAXLEN);
            RecordId recordId = redisTemplate.opsForStream().add(record, options);
            System.out.println("Message sent with ID: " + recordId);

            // 2. WAIT — 최소 1개 replica에 동기 복제 확인 (at-least-once producer 보장)
            // 반환값 0: 단일 노드/복제본 없음 (로컬 환경에서는 정상)
            Long replicas = redisTemplate.execute(
                (RedisCallback<Long>) conn -> conn.serverCommands().waitForReplication(WAIT_REPLICAS, WAIT_TIMEOUT_MS)
            );
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
