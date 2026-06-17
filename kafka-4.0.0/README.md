# Apache Kafka v4.0.0 (KRaft Mode) Air-Gapped Asset

본 디렉토리는 폐쇄망(Air-Gapped) Kubernetes 환경에서 고가용성을 보장하며 즉시 운영 가능한 Apache Kafka v4.0.0 클러스터 설치 자산입니다.

## 🎯 컴포넌트 특징

- **상업용 친화적인 라이선스**: Apache 2.0 라이선스로 배포되는 Bitnami Kafka를 활용하여 상업적 목적의 구축 및 통합에 라이선스 제약이 없습니다.
- **ZooKeeper-less KRaft 아키텍처**: ZooKeeper를 완전히 배제하고, 3개의 카프카 브로커 노드가 자체적으로 Raft 메타데이터 컨트롤러 기능을 병행하여 리소스 소모를 줄이고 장애 조치 속도를 높였습니다.
- **스토리지 결합 기반 스케줄링**: 
  - `hostpath` 사용 시: 노드 고정 배치(`nodeSelector`)를 통해 로컬 스토리지 데이터 무결성을 보장합니다.
  - `nfs` 혹은 `dynamic` 공유 스토리지 사용 시: 파드 분산 배치 정책(`podAntiAffinityPreset: soft`)을 자동 적용하여 노드 장애 대응 가용성(HA)을 극대화합니다.

## 🏗️ 디렉토리 구조

```text
kafka-4.0.0/
├── charts/          # Bitnami Kafka Helm 차트 (32.4.3)
├── images/          # 컨테이너 이미지 아카이브 (.tar) 저장소
├── manifests/       # 정적 PV 매니페스트 (pv-hostpath.yaml, pv-nas.yaml)
├── scripts/         # 설치, 삭제 및 오프라인 패키징용 스크립트
├── values.yaml      # Harbor 연동 배포용 마스터 템플릿
├── values-local.yaml# 로컬 이미지 다이렉트 로드용 마스터 템플릿
└── README.md        # 서비스 명세서
```

## 🛠️ 핵심 스펙 요약

- **Chart Version**: Bitnami Kafka 32.4.3
- **App Version (Kafka)**: 3.9.0
- **Storage Class**: manual (기본값) 또는 사용자 지정 StorageClass
- **Broker Replicas**: 3 (고가용성 확보 최소 요건)
