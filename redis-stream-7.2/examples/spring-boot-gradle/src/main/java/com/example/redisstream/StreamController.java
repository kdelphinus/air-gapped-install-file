package com.example.redisstream;

import com.example.redisstream.producer.RedisStreamProducer;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class StreamController {

    private final RedisStreamProducer producer;

    public StreamController(RedisStreamProducer producer) {
        this.producer = producer;
    }

    @PostMapping("/send")
    public String send(@RequestParam String key, @RequestParam String value) {
        producer.sendMessage(key, value);
        return "sent: " + key + "=" + value;
    }
}
