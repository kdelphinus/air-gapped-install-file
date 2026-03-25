# Redis Stream (HA)

본 컴포넌트는 단일 Kafka/Zookeeper 아키텍처를 대체하기 위해 구성된 **Redis Stream 7.2.4 (Master-Replica-Sentinel HA)** 클러스터입니다.

## 아키텍처 개요

- **Master**: 1대 (Read/Write)
- **Replica**: 2대 (Read-Only)
- **Sentinel**: 3대 (HA 및 Failover 관리)

## Redis Streams vs Kafka 비교

| 영역 | Kafka | Redis Streams |
| --- | --- | --- |
| **Consumer** | Consumer Group + 자동 리밸런싱 지원 | Consumer Group 지원. 단, **자동 리밸런싱 부재**로 앱 레벨의 `XAUTOCLAIM` 필수 |
| **Producer** | acks=all + 브로커 ISR 보장 | `WAIT` 명령어를 통한 동기 복제(앱 레벨) 필요 |
| **OOM 방지** | 디스크 기반 보관 (Retention 정책) | `XADD` 시 반드시 `MAXLEN` 지정 필수 (미지정 시 메모리 100% 점유 위험) |
| **영속성** | 디스크 로그 파일 | AOF(appendfsync everysec) - 최대 1초 유실 가능성 존재 |

## 접속 정보

- **Sentinel 엔드포인트**: `redis-stream.redis-stream.svc:26379`
- **Master Set 이름**: `mymaster`
