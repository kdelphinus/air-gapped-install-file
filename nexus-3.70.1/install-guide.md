# 🚀 Nexus Repository 오프라인 설치 가이드

폐쇄망 환경에서 Nexus3를 설치하고 라이브러리 저장소를 구성하는 절차입니다.

## 1단계: 이미지 로드 및 푸시

```bash
# 1. 이미지 로드
docker load -i images/nexus3-v3.70.1.tar

# 2. Harbor로 푸시
HARBOR_IP="192.168.1.100"
docker tag sonatype/nexus3:3.70.1 ${HARBOR_IP}:30002/library/nexus3:3.70.1
docker push ${HARBOR_IP}:30002/library/nexus3:3.70.1
```

## 2단계: 스토리지(PVC) 준비

`values.yaml`의 `persistence` 설정을 확인합니다. 
이미 구성된 `nfs-provisioner`를 사용하려면 `storageClass: "nfs-provisioner"`를 그대로 둡니다.

## 3단계: Helm 설치

```bash
# 네임스페이스 생성
kubectl create namespace nexus --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치
helm install nexus ./charts/nexus-repository-manager-63.0.0.tgz \
  -n nexus \
  -f values.yaml
```

## 4단계: 초기 비밀번호 확인

설치 후 최초 접속(`30081` 포트) 시 `admin` 계정의 비밀번호는 파드 내부 파일에 저장되어 있습니다.

```bash
kubectl exec -it nexus-0 -n nexus -- cat /nexus-data/admin.password
```

## 5단계: 저장소(Repository) 생성

로그인 후 `Repositories` 메뉴에서 다음을 생성합니다:
1.  **maven2 (hosted)**: Java 라이브러리 저장소
2.  **npm (hosted)**: JavaScript 라이브러리 저장소
3.  **pypi (hosted)**: Python 패키지 저장소
