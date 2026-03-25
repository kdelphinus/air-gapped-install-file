package com.example.redisstream.consumer;

import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.stream.StreamListener;
import org.springframework.data.redis.stream.StreamMessageListenerContainer;
import org.springframework.data.redis.stream.Subscription;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import jakarta.annotation.PostConstruct;
import java.time.Duration;

@Service
public class RedisStreamConsumer implements StreamListener<String, MapRecord<String, String, String>> {

    private final StreamMessageListenerContainer<String, MapRecord<String, String, String>> listenerContainer;
    private final StringRedisTemplate redisTemplate;
    
    private static final String STREAM_KEY = "mystream";
    private static final String GROUP_NAME = "mygroup";
    private static final String CONSUMER_NAME = "consumer1";

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
            // Group already exists
        }

        Subscription subscription = listenerContainer.receive(
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
            
            // 처리 성공 시에만 명시적 ACK 전송 (At-Least-Once Consumer)
            redisTemplate.opsForStream().acknowledge(GROUP_NAME, message);
            System.out.println("ACK sent for ID: " + message.getId());
        } catch (Exception e) {
            System.err.println("Error processing message, will remain in pending list");
        }
    }

    // Consumer가 죽어서 처리하지 못한 메시지(Zombie)를 회수하기 위한 자동 리밸런싱 대체 로직
    @Scheduled(fixedDelay = 30000)
    public void autoClaimZombieMessages() {
        // 실제 운영 환경에서는 XAUTOCLAIM 명령어를 사용하여
        // 일정 시간(예: 30초) 이상 ACK 되지 않은 메시지를 자신의 소유로 가져옵니다.
        // Spring Data Redis 버전에 따라 opsForStream().claim() 메서드 등을 활용합니다.
        System.out.println("Checking for unacknowledged zombie messages...");
    }
}
