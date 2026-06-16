# Jenkins v2.555.3 오프라인 설치 및 빌드 명세

본 문서는 **Jenkins v2.555.3 LTS** (Helm Chart **v5.9.26**) 및 가변형 **OpenTofu 커스텀 빌드 환경** 구성 명세를 정의합니다.

---

## 1. 버전 정보

| 항목 | 사양 | 비고 |
| :--- | :--- | :--- |
| **Jenkins Version** | **v2.555.3 LTS** (최신 안정 버전) | CI/CD 자동화 플랫폼 |
| **Helm Chart** | **v5.9.26** | 공식 jenkins/jenkins 차트 버전 |
| **대상 OS** | Rocky Linux (RHEL-based) / Ubuntu (Debian-based) | 클러스터 호스트 OS |

---

## 2. 기본 포함 컨테이너 이미지 (3종)

에어갭 오프라인 환경 구성을 위해 반입되어야 하는 기본 이미지 목록입니다.

| 이미지 명 | 버전 Tag | 용도 |
| :--- | :--- | :--- |
| `jenkins/jenkins` | `2.555.3-jdk21` | Jenkins 컨트롤러 (기본 배포본) |
| `jenkins/inbound-agent` | `3355.v388858a_47b_33-22` | Jenkins 빌드 에이전트 Pod |
| `kiwigrid/k8s-sidecar` | `2.7.3` | JCasC (Jenkins Configuration as Code) 자동 리로드 모듈 |

---

## 3. OpenTofu 커스텀 빌드 사양 (사용자 조정 가변 툴체인)

Jenkins 환경 내부에서 OpenTofu 파이프라인을 구동하기 위해 사용자가 프로바이더(CSP) 및 버전을 조정하여 **`cmp-jenkins-full:2.555.3`** 커스텀 이미지를 자체 빌드할 수 있는 툴체인을 제공합니다.

* **OpenTofu 기본 버전**: `v1.6.0` (입력에 따라 가변 조정 가능)
* **지원 가능 CSP 및 드라이버 버전**:
  * **AWS**: `v5.30.0`
  * **Azure**: `v3.85.0`
  * **VMware**: `v2.6.0`
  * **OpenStack**: `v1.53.0`
* **공통 내장 툴**: `kubectl v1.28.4`, `helm v3.13.2`

---

## 4. 디렉토리 구조

```text
jenkins-2.555.3/
├── charts/          # Helm 차트 (jenkins-5.9.26.tgz 원본 및 압축 해제 폴더)
├── images/          # 기본 이미지 (.tar) 및 빌드 완료된 커스텀 이미지 저장소
├── manifests/       # 정적 K8s 매니페스트 (PV/PVC 정의, HTTPRoute)
│   ├── pv-volume.yaml             # Jenkins 홈 PV 정의
│   ├── gradle-cache-pv-pvc.yaml   # 에이전트용 Gradle 의존성 캐시 볼륨
│   └── route-jenkins.yaml         # Envoy Gateway 연동용 HTTPRoute
├── jenkins-build/   # OpenTofu 커스텀 이미지 빌드 툴체인
│   ├── Dockerfile                 # 베이스 2.555.3 커스텀 도커파일
│   ├── plugins.txt                # 플러그인 목록 정의서
│   ├── build-tofu-jenkins.sh      # 대화형 빌드 제어 스크립트 (CSP/Tofu 버전 가변)
│   └── bundle-providers.sh        # 통합형 프로바이더 및 툴 다운로더
├── scripts/         # 설치 및 운영 스크립트 (루트 상대 경로 실행 필수)
│   ├── install.sh                 # 표준 대화형 설치 스크립트 (values-override.yaml 동기화)
│   ├── uninstall.sh               # clean up 스크립트
│   ├── download_assets_offline.sh # 오프라인 이미지/차트 획득용 도구
│   └── upload_images_to_harbor_v3-lite.sh # Harbor 업로드 도구 (skopeo copy 지원)
├── values.yaml      # 기본 설정 값
└── values.yaml.orig # values.yaml 백업 원본 (install.sh가 멱등성 보장용으로 사용)
```
