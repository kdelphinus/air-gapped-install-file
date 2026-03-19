# 🚀 Velero 오프라인 설치 가이드

폐쇄망 환경에서 K8s 클러스터 백업 체계를 구축하는 절차입니다.

## 1단계: CLI 및 이미지 준비

Velero는 서버 설치 외에 로컬 실행 파일(`velero`)이 필요합니다.

```bash
# 1. CLI 바이너리 설치
tar -xvf scripts/velero-v1.14.1-linux-amd64.tar.gz
sudo mv velero /usr/local/bin/

# 2. 이미지 로드 및 푸시
docker load -i images/velero-v1.14.1.tar
docker load -i images/velero-plugin-for-aws-v1.10.1.tar
# (Harbor로 태그 변경 및 푸시 진행)
```

## 2단계: 백업 저장소(S3/MinIO) 준비

Velero는 백업 파일을 저장할 오브젝트 스토리지가 필요합니다. 
이미 구축된 **MinIO**가 있다면 해당 주소를 `values.yaml`의 `s3Url`에 기입합니다.

## 3단계: Helm 설치

```bash
# 네임스페이스 생성
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -

# 헬름 설치
helm install velero ./charts/velero-7.2.1.tgz \
  -n velero \
  -f values.yaml
```

## 4단계: 백업 테스트

```bash
# 즉시 백업 실행
velero backup create test-backup --include-namespaces default

# 백업 상태 확인
velero backup get
velero backup describe test-backup
```

## 5단계: 복구 테스트

```bash
# 리소스 삭제 후 복구 시도
kubectl delete deployment <app-name>
velero restore create --from-backup test-backup
```
