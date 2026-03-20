# 🚀 Ingress-Nginx v4.10.1 오프라인 설치 가이드

폐쇄망 환경에서 Ingress-Nginx Controller v4.10.1을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료 (master + worker)
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Ingress Controller 이미지 `.tar` 파일 준비 완료

## 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

이미지 로드 확인:

```bash
sudo ctr -n k8s.io images list | grep ingress
```

## 2단계: 설치 스크립트 설정

`scripts/ingress_controller_install_offline.sh` 상단 Config 블록을 환경에 맞게 수정합니다.

| 변수 | 설명 | 기본값 |
| :--- | :--- | :--- |
| `NAMESPACE` | Ingress Controller 설치 네임스페이스 | `ingress-nginx` |
| `RELEASE_NAME` | Helm release 이름 | `ingress-nginx` |
| `HELM_CHART_PATH` | Helm 차트 파일 경로 | `./charts/ingress-nginx-4.10.1.tgz` |

## 3단계: Ingress Controller 설치 실행

```bash
chmod +x scripts/ingress_controller_install_offline.sh
./scripts/ingress_controller_install_offline.sh
```

특정 노드를 지정하여 설치합니다. 외부에서 해당 노드의 IP로 접근 가능하면 Ingress Controller를 통해 Kubernetes 서비스에 접근할 수 있습니다.

## 4단계: 설치 확인

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

### 포트 확인

| 프로토콜 | 호스트 포트 | NodePort | 용도 |
| :--- | :--- | :--- | :--- |
| **HTTP** | 80 | 30007 | 일반 웹 트래픽 |
| **HTTPS** | 443 | 32647 | 보안 웹 트래픽 |

## 💡 주의 사항

- **HostNetwork 모드**: HostNetwork 모드로 동작하므로 해당 노드에서 80, 443 포트를 다른 프로세스가 사용하고 있지 않아야 합니다.
- **TLS 설정**: TLS 사용 시 DNS 등록과 TLS 인증서 내 도메인이 일치해야 합니다.
- **트러블슈팅**: 문제 발생 시 `kubectl logs`로 Ingress Pod 로그를 확인합니다.
