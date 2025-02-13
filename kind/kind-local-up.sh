#!/usr/bin/env bash

set -e


POD_SUBNET="192.168.254.0/30" # for testing exhaustion @peri
POD_SUBNET="192.168.254.0/16"
CLUSTER=${CLUSTER:-calico}
CONFIG=${CONFIG:-calico-conf.yaml}
API_SERVER_ADDRESS="192.168.1.35"
API_SERVER_PORT=6443

# Usage examples:
#CLUSTER=nocni CONFIG="calico-conf.yaml" ./kind-local-up.sh
#CLUSTER=cipv6 CONFIG=kind-conf-ipv6.yaml ./kind-local-up.sh
# Calico usage - CLUSTER=calico CONFIG=kind-conf.yaml ./kind-local-up.sh
# Antrea usage - CLUSTER=antrea CONFIG=kind-conf.yaml ./kind-local-up.sh
# Cilium usage - CLUSTER=cilium CONFIG=cilium-conf.yaml ./kind-local-up.sh
# Cilium-ingress usage - CLUSTER=cilium-ingress CONFIG=cilium-ingress.yaml ./kind-local-up.sh

function check_kind() {
    if [ kind > /dev/null ]; then
        echo "Kind binary not found."
        exit 1
    fi
}

function init_configuration() {
    # Thanks to https://alexbrand.dev/post/creating-a-kind-cluster-with-calico-networking/ for this snippet :)
    cat << EOF > calico-conf.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true # disable kindnet
  podSubnet: $POD_SUBNET
  apiServerPort: $API_SERVER_PORT
  apiServerAddress: $API_SERVER_ADDRESS
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

    cat << EOF > cilium-conf.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
# - role: worker
# - role: worker
networking:
  disableDefaultCNI: true
  apiServerPort: $API_SERVER_PORT
  apiServerAddress: $API_SERVER_ADDRESS
EOF

    cat << EOF > cilium-ingress.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
  extraPortMappings:
    - containerPort: 80
      hostPort: 8080
      listenAddress: "0.0.0.0"
    - containerPort: 443
      hostPort: 8443
      listenAddress: "0.0.0.0"
networking:
  disableDefaultCNI: true
  apiServerPort: $API_SERVER_PORT
  apiServerAddress: $API_SERVER_ADDRESS
EOF
}

#cluster=nocni
#conf="calico-conf.yaml"

#cluster=cipv6
#conf=kind-conf-ipv6.yaml

## calico conf == no cni, so use it for antrea/calico/whatever
cluster=antrea
conf=calico-conf.yaml

# cluster=calico
# conf=calico-conf.yaml

cluster=calico
conf=calico-conf.yaml

function install_k8s() {
    if kind delete cluster --name=${CLUSTER}; then
    	echo "deleted old kind cluster, creating a new one..."
    fi
    kind create cluster --name=${CLUSTER} --config=${CONFIG}
    until kubectl cluster-info;  do
        echo "`date` waiting for cluster..."
        sleep 2
    done
}

function install_calico() {
    kubectl get pods
    # this might fail ... if so, no problem, we just use calico.yaml thats in the github repo here :)...
    # curl https://docs.projectcalico.org/manifests/calico.yaml -O
    kubectl apply -f ./calico.yaml
    kubectl get pods -n kube-system
    kubectl -n kube-system set env daemonset/calico-node FELIX_IGNORELOOSERPF=true
    kubectl -n kube-system set env daemonset/calico-node FELIX_XDPENABLED=false
}

function install_antrea() {
	if [[ ! -d antrea ]] ; then
	    git clone https://github.com/vmware-tanzu/antrea.git
	fi
	pushd antrea
	     # this patches the container version to v1.3.0
	     git stash
	     cp ../antrea.patch .
	     git checkout 62e25bf1ead28b5d5c8fa5bc93363b758b34686e
         patch -p 1 < antrea.patch
	     pushd ci/kind
    	      ./kind-setup.sh create antrea
	     popd
	popd
}

function install_cilium() {
    CILIUM_VERSION="1.14.2"

    # Add Cilium Helm repo
    helm repo add cilium https://helm.cilium.io/

    # Pre-load images
    docker pull cilium/cilium:"v${CILIUM_VERSION}"

    # Install cilium with Helm
    helm install cilium cilium/cilium --version ${CILIUM_VERSION} \
         --namespace kube-system \
         --set nodeinit.enabled=true \
         --set kubeProxyReplacement=partial \
         --set hostServices.enabled=false \
         --set externalIPs.enabled=true \
         --set nodePort.enabled=true \
         --set hostPort.enabled=true \
         --set bpf.masquerade=false \
         --set image.pullPolicy=IfNotPresent \
         --set ipam.mode=kubernetes
}

function wait() {
    sleep 5 ; kubectl -n kube-system get pods
    echo "will wait for calico/antrea/... to start running now... "
    while true ; do
        kubectl -n kube-system get pods
        sleep 3
    done
}

function testStatefulSets() {
   sonobuoy run --e2e-focus "Basic StatefulSet" --e2e-skip ""
}

init_configuration
sleep 1

case "$CLUSTER" in
    "antrea")
        echo "Using Antrea/master setup script for kind"
        install_antrea
        ;;
    "calico")
        echo "Using Calico CNI."
        install_k8s
        install_calico
        ;;
    "cilium")
        echo "Using Cilium CNI."
        install_k8s
        install_cilium
        ;;
    "cilium-ingress")
        echo "Using Cilium CNI."
        install_k8s
        install_cilium
        ;;
    "*")
        echo "Skipping CNI"
        ;;
esac
