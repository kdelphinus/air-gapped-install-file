# Kubernetes v1.33.11 Ubuntu 24.04 재현성 검증

이 문서는 기존 고정 산출물 `k8s-1.33.11-ubuntu24.04`를 기준으로 `k8s-offline-builder`가 동일한 수준의 설치 번들을 재현할 수 있는지 비교한 결과입니다.

검증 기준은 현재 저장소에 포함된 기존 산출물과 builder의 수집/빌드/설치 로직입니다. 아직 외부망 Ubuntu 24.04 호스트에서 builder의 `download.sh`를 끝까지 실행한 것은 아니므로, 최종 DEB/이미지 파일 수량과 목록 일치는 실제 수집 후 다시 확인해야 합니다.

## 기준 산출물 요약

| 구분 | 기존 번들 | builder 생성 경로 | 상태 |
| --- | ---: | --- | --- |
| DEB 패키지 | 109개 | `k8s/debs` | 재현 가능 |
| 바이너리 tarball | 2개 | `k8s/binaries` | 재현 가능 |
| 컨테이너 이미지 | 16개 | `k8s/images` | Calico 기준 재현 가능 |
| 유틸 YAML | 4개 | `k8s/utils` | 재현 가능 |
| Cilium Helm chart | 외부 컴포넌트 사용 | `k8s/charts` | builder에서 확장 |

기존 이미지 기준 목록:

- `kube-apiserver-v1.33.11.tar`
- `kube-controller-manager-v1.33.11.tar`
- `kube-scheduler-v1.33.11.tar`
- `kube-proxy-v1.33.11.tar`
- `etcd-3.5.24-0.tar`
- `coredns-coredns-v1.12.0.tar`
- `pause-3.10.tar`
- `tigera-operator-v1.40.0.tar`
- `calico-cni-v3.31.0.tar`
- `calico-node-v3.31.0.tar`
- `calico-kube-controllers-v3.31.0.tar`
- `calico-typha-v3.31.0.tar`
- `calico-pod2daemon-flexvol-v3.31.0.tar`
- `calico-csi-v3.31.0.tar`
- `calico-node-driver-registrar-v3.31.0.tar`
- `calico-apiserver-v3.31.0.tar`

## 디렉터리 구조 비교

| 항목 | 기존 번들 | builder 생성 번들 | 판정 |
| --- | --- | --- | --- |
| `k8s/debs` | 포함 | 포함 | 일치 |
| `k8s/binaries` | 포함 | 포함 | 일치 |
| `k8s/images` | 포함 | 포함 | 일치 |
| `k8s/utils` | 포함 | 포함 | 일치 |
| `k8s/charts` | 없음 | 포함 | Cilium 내장 설치를 위한 확장 |
| `scripts/install.sh` | 포함 | 템플릿에서 생성 | 재현 가능 |
| `scripts/uninstall.sh` | 포함 | 템플릿에서 생성 | 재현 가능 |
| `scripts/wsl2_prep.sh` | 포함 | 템플릿에서 생성 | 재현 가능 |
| `install-guide*.md` | 고정 번들에 포함 | builder 공통 문서 중심 | 번들별 문서 생성 여부 후속 결정 |
| `reboot-guide.md` | 포함 | 미생성 | 후속 결정 필요 |

## 설정 항목 비교

| 설정 | 기존 번들 | builder | 판정 |
| --- | --- | --- | --- |
| `K8S_VERSION` | 스크립트 고정값 | `install.conf` 기반 | 개선 |
| `TARGET_OS` | 디렉터리명에 고정 | `install.conf`와 compatibility 정책 기반 | 개선 |
| `CNI_CHOICE` | 대화형 선택 후 저장 | 설정 기반, 설치 시 대화형 보완 | 재현 가능 |
| `CALICO_INSTALL_METHOD` | `manifest` 또는 `operator` | `manifest` 또는 `operator` | 일치 |
| `CNI_INSTALL_MODE` | `auto` 또는 `manual` | 기본 `auto`, 설정으로 `manual` 가능 | 재현 가능 |
| `GATEWAY_INSTALL_MODE` | Envoy 자동 호출 제어 | 없음 | 의도적 차이 |
| `ENABLE_HUBBLE`, `MTU_VALUE` | 외부 Cilium 컴포넌트에서 관리 | K8s 생성 번들 설정에 포함 | 개선 |
| `CONTROL_PLANE_ENDPOINT` | 대화형 입력 후 저장 | 대화형 입력 후 저장 | 일치 |
| `CRI_SOCKET` | 기본값 저장 | 기본값 저장 | 일치 |

## 설치 기능 비교

| 기능 | 기존 번들 | builder 템플릿 | 판정 |
| --- | --- | --- | --- |
| WSL2/VM 감지 | 지원 | 지원 | 일치 |
| WSL2 systemd 확인 | 지원 | 지원 | 일치 |
| 시간 동기화 확인 | 지원 | 지원 | 일치 |
| DEB 오프라인 설치 | 지원 | 지원 | 일치 |
| swap 영구 비활성화 | 지원 | 지원 | 일치 |
| kernel module/sysctl 설정 | 지원 | 지원 | 일치 |
| fd/inotify/systemd limits | 지원 | 지원 | 일치 |
| containerd systemd cgroup | 지원 | 지원 | 일치 |
| 이미지 pre-load | 지원 | 지원 | 일치 |
| `kubeadm init` | 지원 | 지원 | 일치 |
| worker join | 지원 | 지원 | 일치 |
| 추가 control-plane join | 지원 | 지원 | 일치 |
| HAProxy 6443 포트 충돌 회피 | 지원 | 지원 | 일치 |
| kubeconfig 설정 | root와 sudo 사용자 | root와 sudo 사용자 | 일치 |
| WSL2 control-plane taint 제거 | 지원 | 지원 | 일치 |
| Calico manifest 설치 | 지원 | 지원 | 일치 |
| Calico Tigera operator 설치 | 지원 | 지원 | 일치 |
| Cilium 설치 | 외부 `../cilium-1.19.3` 호출 | 번들 내부 chart/image로 설치 | 개선 |
| Envoy Gateway 자동 호출 | 외부 `../envoy-1.37.2` 호출 | 없음 | 의도적 차이 |

## 수집 로직 비교

| 수집 대상 | 기존 `download.sh` | builder `download.sh` | 판정 |
| --- | --- | --- | --- |
| Kubernetes APT repo | `v1.33` 고정 | `K8S_VERSION`에서 minor 자동 계산 | 개선 |
| Docker CE repo | Ubuntu codename 기반 | Ubuntu codename 기반 | 일치 |
| kubeadm/kubelet/kubectl | `1.33.11-1.1` 고정 | `K8S_VERSION`에서 자동 계산 | 개선 |
| containerd.io | 최신 또는 고정 | `auto` 또는 고정 | 일치 |
| 유틸 패키지 | conntrack, socat, ebtables, ipset, jq, chrony, haproxy, keepalived, psmisc | 동일 목록 | 일치 |
| Helm | `v3.20.2` | 설정 기반 `v3.20.2` | 일치 |
| nerdctl | `2.2.2` | 설정 기반 `2.2.2` | 일치 |
| Calico YAML | 3종 | 3종 | 일치 |
| local-path-storage | 포함 | 포함 | 일치 |
| Kubernetes core images | `kubeadm config images list` | 동일 | 일치 |
| Calico images | 고정 목록 + operator 이미지 동적 추출 | 동일 계열 | 일치 |
| Cilium chart/images | 외부 컴포넌트 담당 | builder에서 직접 수집 | 확장 |
| 임시 APT repo 정리 | 명시 정리 | trap 기반 정리 | 개선 |

## 의도적 차이와 후속 결정

| 차이 | 설명 | 권장 처리 |
| --- | --- | --- |
| Envoy Gateway 자동 설치 제외 | 기존 번들은 Calico 설치 후 `../envoy-1.37.2/scripts/install.sh`를 호출할 수 있습니다. builder는 Kubernetes/CNI 번들 범위에 집중하도록 외부 컴포넌트 자동 호출을 제외했습니다. | K8s builder에 넣기보다 별도 component orchestration 단계에서 연결 권장 |
| `reboot-guide.md` 미생성 | 기존 고정 번들에는 별도 재부팅 가이드가 있습니다. | 생성 README 또는 번들별 문서 템플릿에 흡수할지 결정 필요 |
| Cilium 설치 방식 변경 | 기존은 외부 `cilium-1.19.3` 컴포넌트 호출, builder는 chart/images를 번들 내부에 포함합니다. | builder 방식 유지 권장 |
| 실제 파일 수량 미검증 | builder를 외부망에서 끝까지 실행하지 않았습니다. | 실환경 수집 시 파일 수량과 목록 비교 필요 |

## 실제 수집 시 체크리스트

외부망 Ubuntu 24.04 호스트에서 다음 순서로 확인합니다.

```bash
cd k8s-offline-builder
sudo ./scripts/download.sh
./scripts/build_bundle.sh
```

생성 후 확인할 항목:

- `k8s/debs/*.deb`가 기존 기준 109개 수준으로 수집되는지 확인
- `k8s/binaries/helm-v3.20.2-linux-amd64.tar.gz` 존재 확인
- `k8s/binaries/nerdctl-full-2.2.2-linux-amd64.tar.gz` 존재 확인
- Calico 선택 시 기존 Kubernetes core/Calico 이미지 세트와 동등한 이미지가 생성되는지 확인
- Cilium 선택 시 `k8s/charts/cilium-1.19.3.tgz`와 Cilium 이미지가 생성되는지 확인
- `k8s/utils/calico.yaml`, `tigera-operator.yaml`, `calico-custom-resources.yaml`, `local-path-storage.yaml` 존재 확인
- 생성된 스크립트 문법 검사:

```bash
bash -n bundles/k8s-v1.33.11-ubuntu24.04/scripts/install.sh
bash -n bundles/k8s-v1.33.11-ubuntu24.04/scripts/uninstall.sh
bash -n bundles/k8s-v1.33.11-ubuntu24.04/scripts/wsl2_prep.sh
```

## 결론

현재 builder는 기존 `k8s-1.33.11-ubuntu24.04`의 Kubernetes 설치 핵심 기능을 대부분 재현합니다. 특히 버전, OS, CNI, compatibility 판단을 설정과 정책 파일로 분리했고, Cilium은 외부 컴포넌트 호출보다 독립적인 번들 내부 설치 방식으로 확장되었습니다.

남은 검증은 실제 외부망 수집 결과와 기존 산출물의 파일 목록 비교입니다. 이 검증 전까지는 builder를 기능적으로 정렬된 상태로 보고, 파일 단위 재현성은 실수집 후 확정하는 것이 안전합니다.
