# 📝 OpenTelemetry Operator Infrastructure Specification

본 문서는 **OpenTelemetry Operator v0.152.0** 및 **Helm Chart v0.114.1**을 기반으로 구축된 Kubernetes 애플리케이션 자동 계측(Auto-Instrumentation) 및 콜렉터 동적 관리 제어 시스템 명세를 정의합니다.

## 1. 시스템 버전 정보 (Version Specification)

폐쇄망 환경의 성능 진단 자동화 및 관리 표준 준수를 위해 다음 버전이 적용되었습니다.

| 항목 | 버전 | 비고 |
| --- | --- | --- |
| **OpenTelemetry Operator** | **v0.152.0** | 오퍼레이터 제어부 (Ghcr 이미지 탑재) |
| **Helm Chart** | **v0.114.1** | open-telemetry/opentelemetry-operator 공식 헬름 차트 |
| **K8s 호환성** | **v1.24 이상** | 표준 Kubernetes API 기반 동작 |
| **사전 요구사항** | **cert-manager** | 어드미션 웹훅 TLS 인증서 관리용 필수 자원 |

---

## 2. 시스템 아키텍처 및 역할 (Architecture)

OpenTelemetry Operator는 Kubernetes Custom Resource Definition(CRD)을 사용하여 애플리케이션 모니터링 환경을 코드로 관리하고 자동화합니다.

### 🔹 핵심 커스텀 리소스 (Custom Resources)
* **Instrumentation (계측 정의)**: 
  * 개발자가 애플리케이션 소스 코드를 수정하지 않고도 모니터링 에이전트(Java, NodeJS, Python, Go, .NET 등)를 파드 시작 단계에 자동으로 주입(Auto-injection)하는 규격을 설정합니다.
* **OpenTelemetryCollector (동적 수집기)**:
  * YAML 정의서 하나로 OTel Collector의 배포 및 오토스케일링을 오퍼레이터가 클러스터 내에서 동적으로 수행하도록 위임합니다.

### 🔹 어드미션 웹훅 (Admission Webhooks)
* **역할**: 파드가 새로 생성되거나 변경될 때(`mutating`/`validating`), 파드 사양을 스캔하여 `Instrumentation` 어노테이션이 존재할 시 OTel 에이전트 컨테이너를 파드에 실시간 인젝션합니다.
* **보안 사양**: API 서버와 오퍼레이터 간의 안전한 통신을 보장하기 위해 **cert-manager**가 발급하는 TLS 인증서를 통해 인증이 강제됩니다.

---

## 3. 사전 요구사항 검증 (Prerequisites)

OpenTelemetry Operator는 **cert-manager**가 미설치되어 있거나 비정상 작동 상태일 경우, 어드미션 웹훅 모듈이 작동하지 않아 파드 배포 자체가 차단되거나 오퍼레이터가 비정상 종료(Exit 1)됩니다.

* **필수 검증 대상**: `certificates.cert-manager.io` CRD
* **검증 방법 (install.sh 내 자동 포함)**:
  ```bash
  kubectl get crd certificates.cert-manager.io
  ```

---

## 4. 폐쇄망 운영 가이드 (Operational Guide)

### ✅ 오퍼레이터 기동 상태 진단
```bash
# 오퍼레이터 컨트롤러 작동 로그 스캔
kubectl logs -f -n opentelemetry -l app.kubernetes.io/name=opentelemetry-operator
```

### ✅ 웹훅 교착 상태 해결
오퍼레이터를 강제 삭제하거나 비정상 종료한 후, 웹훅 어드미션 컨트롤러 설정이 클러스터 전역에 잔존해 있으면 신규 파드 배포 시 타임아웃 오류가 발생할 수 있습니다. 이 경우 아래 웹훅 리소스를 수동 정리하십시오.

```bash
kubectl delete mutatingwebhookconfiguration otel-operator-mutating-webhook-configuration --ignore-not-found=true
kubectl delete validatingwebhookconfiguration otel-operator-validating-webhook-configuration --ignore-not-found=true
```
