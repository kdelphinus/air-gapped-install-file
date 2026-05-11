kubectl create ns trident
helm install trident netapp-trident/trident-operator --namespace trident --version 100.2506.3 --set kubeletDir="/var/lib/kubelet"
