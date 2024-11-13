#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

CLUSTER_NAME="quickops-cluster"
API_SERVER_IP=$1

if command -v docker &>/dev/null;then
    echo "====================================================="
    echo "✅ docker is already installed: $(docker --version)"
    echo "====================================================="

else
    echo "================================================="
    echo "❌ docker is not installed. Installing....."
    echo "================================================="

    sudo apt install apt-transport-https ca-certificates curl software-properties-common -y
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install docker-ce -y

    sudo usermod -aG docker $USER
    sudo chmod 666 /var/run/docker.sock

    echo "================================================="
    echo "✅ docker has been installed successfully!"
    echo "================================================="

fi


# Check if kind is already installed
if command -v kind &>/dev/null; then
    echo "====================================================="
    echo "✅ kind is already installed: $(kind --version)"
    echo "====================================================="
else
    echo "================================================="
    echo "❌ kind is not installed. Installing....."
    echo "================================================="
    # Check the system architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        # Define the kind version you want to install
        KIND_VERSION="v0.25.0"
        
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64

        # Make the binary executable
        chmod +x ./kind

        # Move the binary to a directory in your PATH
        sudo mv ./kind /usr/local/bin/kind
        echo "================================================="
        echo "✅ kind has been installed successfully"
        echo "================================================="
    else
        echo "================================================="
        echo "❌ Unsupported architecture: $ARCH"
        echo "================================================="
        
        exit 1
    fi
fi


# Check if kubectl is already installed
if command -v kubectl &>/dev/null; then
    echo "================================================================="
    echo "✅ kubectl is already installed: $(kubectl version)"
    echo "================================================================="
else
    echo "================================================================="
    echo "❌ kubectl is not installed, installing...."
    echo "================================================================="
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    echo "============================="
    echo "✅ kubectl installed"
    echo "============================="
fi




# Cleanup function to delete the cluster if the script fails
cleanup() {
  echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
  echo "    An error occurred. Deleting the cluster..."
  echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

  kind delete cluster --name $CLUSTER_NAME
}
# Set trap to call cleanup on error or interrupt
trap cleanup ERR INT

echo "=========================================================="
echo "Creating Kubernetes cluster using kind..."
echo "=========================================================="

# Create the Kubernetes cluster
kind create cluster --name $CLUSTER_NAME --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: $API_SERVER_IP
  apiServerPort: 6443
nodes:
  - role: control-plane
    image: kindest/node:v1.28.0
  - role: worker
    image: kindest/node:v1.28.0
  - role: worker
    image: kindest/node:v1.28.0
EOF

kind_image_name="$CLUSTER_NAME-control-plane"
kind_docker_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $kind_image_name | awk -F. '{print $1 "." $2}')
kind_docker_range_first="$kind_docker_ip.255.200"
kind_docker_range_last="$kind_docker_ip.255.250"


echo "====================================="
echo "Deploying MetalLB..."
echo "====================================="

# Deploy MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml

# Wait for MetalLB pods to be ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=390s

echo "=========================================="
echo "Configuring MetalLB IP address pool..."
echo "=========================================="

# Configure MetalLB IP address pool
kubectl create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: example
  namespace: metallb-system
spec:
  addresses:
    - "$kind_docker_range_first-$kind_docker_range_last"
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF

if command -v helm &>/dev/null; then
    echo "==========================================================="
    echo "✅ helm is already installed: $(helm version)"
    echo "==========================================================="
else
    echo "================================================================="
    echo "❌ helm is not installed, installing...."
    echo "================================================================="
    curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    sudo apt install apt-transport-https --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt update
    sudo apt install helm -y
    echo "================================"
    echo "✅ helm is installed"
    echo "================================"
fi

echo "====================================="
echo "Deploying Quickops..."
echo "====================================="
helm upgrade -i aescontroller ./aescontroller -n aescloud-engine --create-namespace
helm upgrade -i operator-dependencies ./dependent-manifests -n aescloud-engine 

kubectl create -f - <<EOF
apiVersion: webapp.aes.dev/v1
kind: CorePod
metadata:
  labels:
    app.kubernetes.io/name: corepod
    app.kubernetes.io/instance: corepod-sample
    app.kubernetes.io/part-of: orgpod
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/created-by: orgpod
  name: core
spec:
  goImg: "devopsaes/kuberaes:singlelb.0.0.6"
  beReplicas: 1
EOF

echo "====================================="
echo "✅ Quickops deployed..."
echo "====================================="

