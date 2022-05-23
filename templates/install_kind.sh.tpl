#!/usr/bin/env bash

# install packages
while ! apt-get update
do
  echo "Failed to get updates...retrying"
  sleep 10
done
apt install -y docker.io jq


# Install kind binary
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.13.0/kind-linux-amd64
chmod +x ./kind
mv kind /usr/local/bin/kind

# Create kind config for cluster
cat << EOF > kind.conf
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.21.2@sha256:6f19412d7d7c4156b3302d4de16168227173f155271be69250893e5c8585cb86
- role: worker
  image: kindest/node:v1.21.2@sha256:6f19412d7d7c4156b3302d4de16168227173f155271be69250893e5c8585cb86
  extraPortMappings:
  - containerPort: 31666
    hostPort: 8200
    protocol: TCP
networking:
  apiServerAddress: $(ec2metadata --local-ipv4)
  apiServerPort: 6443
EOF





