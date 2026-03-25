package com.example.redisstream.producer;

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
    private static final long MAXLEN = 100000L; // OOM 방지 필수

    public RedisStreamProducer(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    public void sendMessage(String key, String value) {
        Map<String, String> message = Collections.singletonMap(key, value);
        try {
            StringRecord record = StreamRecords.string(message).withStreamKey(STREAM_KEY);
            
            // 1. MAXLEN을 지정하여 스트림 크기 제한 (OOM 방지)
            XAddOptions options = XAddOptions.maxlen(MAXLEN);
            RecordId recordId = redisTemplate.opsForStream().add(record, options);
            
            // 2. 최소 1개 Replica 동기 복제 대기 (At-Least-Once Producer)
            // 참고: Spring Data Redis의 opsForStream()에는 WAIT가 내장되어 있지 않으므로 
            // 커넥션을 직접 얻어 wait() 명령을 실행해야 완벽한 동기 복제가 됩니다.
            // 여기서는 개념적 예시로 로컬 버퍼 활용 로직만 구현합니다.
            
            System.out.println("Message sent with ID: " + recordId);
        } catch (Exception e) {
            System.err.println("Send failed, buffering locally...");
            localBuffer.offer(message); // 실패 시 버퍼에 저장하여 유실 방지
        }
    }

    @Scheduled(fixedDelay = 5000)
    public void flushBuffer() {
        Map<String, String> msg;
        while ((msg = localBuffer.poll()) != null) {
            sendMessage(msg.keySet().iterator().next(), msg.values().iterator().next());
        }
    }
}
