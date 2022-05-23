# Get helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add hashicorp repo to helm
helm repo add hashicorp https://helm.releases.hashicorp.com

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Create gossip key secret
kubectl create secret generic vault-storage-consul-gossip-key --from-literal=key=$(uuidgen | tr -d '-')

# Create consul chart values
cat << EOF > helm-consul-values.yaml
global:
  name: consul
  datacenter: vault-storage
  image: hashicorp/consul:1.11.3
  imageK8S: hashicorp/consul-k8s-control-plane:0.43.0
  acls:
    manageSystemACLs: true
  gossipEncryption:
    secretName: vault-storage-consul-gossip-key
    secretKey: key
  tls:
    enabled: true
    enableAutoEncrypt: true
    httpsOnly: false
  enablePodSecurityPolicies: true

ui:
  enabled: false

dns:
  enabled: false

client:
  enabled: false
  image: hashicorp/consul:1.11.3

server:
  replicas: 3
  updatePartition: 0
  bootstrapExpect: 3
  disruptionBudget:
    enabled: true

  # affinity: null allows deploying multiple pods to the same node
  # remove if the cluster has at least one node per Consul server pod
  affinity: null
EOF

# Install consul in cluster
helm install consul hashicorp/consul --version="0.42.0" -f helm-consul-values.yaml

# Create the bootstrap tokens for vault
ACL_BOOTSTRAP_TOKEN="$(
    kubectl get \
        secrets/consul-bootstrap-acl-token \
        --template={{.data.token}} | \
        base64 --decode
)"

# Create Vault token
kubectl exec consul-server-0 -- consul acl policy create \
    -token "$ACL_BOOTSTRAP_TOKEN" \
    -name vault-storage \
    -rules '
key_prefix "vault/" {
    policy = "write"
}
node_prefix "" {
    policy = "write"
}
service "vault" {
    policy = "write"
}
agent_prefix "" {
    policy = "write"
}
session_prefix "" {
    policy = "write"
}
'

VAULT_ACL="$(
    kubectl exec -it consul-server-0 -- sh -c "consul acl token create \
        -token $ACL_BOOTSTRAP_TOKEN \
        -description 'Token for Vault Service' \
        -policy-name vault-storage \
        -format json | \
        jq -r '.SecretID'" | tr -d '\r'
)"

kubectl create secret generic \
    vault-acl-token \
    --from-literal=token="$VAULT_ACL"

cat <<EOF > helm-vault-values.yaml
injector:
  image:
    repository: hashicorp/vault-k8s
    tag: 0.14.2
  agentImage:
    repository: hashicorp/vault
    tag: 1.9.3

global:
  enabled: true
  tlsDisable: true
  psp:
    enable: true

server:
  image:
    repository: hashicorp/vault
    tag: 1.9.3

  extraSecretEnvironmentVars:
    - envName: CONSUL_HTTP_TOKEN
      secretName: vault-acl-token
      secretKey: token

  # affinity: null allows deploying multiple pods to the same node
  # remove if the cluster has at least one node per pod
  affinity: null

  auditStorage:
    enabled: true
    size: 250Mi
  service:
    enabled: true

  ha:
    enabled: true
    replicas: 3

    config: |
      ui = true

      listener "tcp" {
        address = "0.0.0.0:8200"
        cluster_address = "0.0.0.0:8201"

        tls_disable = true

        telemetry {
          unauthenticated_metrics_access = true
        }
      }

      storage "consul" {
        path = "vault"
        address = "consul-server:8500"
        tls_skip_verify = "true"
      }

      service_registration "kubernetes" {}
EOF

helm install vault hashicorp/vault --version="0.19.0" -f helm-vault-values.yaml
# wait for vault-0 to be ready
while ! [ "$(kubectl get po vault-0 -o json 2>/dev/null | jq -r '.status.phase')" == "Running" ]
do
  echo "Waiting for vault-0 to be ready"
  sleep 10
done

kubectl exec -i vault-0 -- \
    /bin/sh -c 'vault operator init -key-shares=1 -key-threshold=1 -format=json' > init.json

export UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' ./init.json)

for i in 0 1 2
do
    kubectl exec -ti vault-$${i} -- /bin/sh -c 'vault operator unseal '$${UNSEAL_KEY}''
done

cat << EOF > vault-node-port.yaml
kind: Service
apiVersion: v1
metadata:
  name: vault-node-port
spec:
  type: NodePort 
  ports:
    - nodePort: 31666
      port: 8200
      targetPort: 8200

  selector:
    app.kubernetes.io/instance: vault
    app.kubernetes.io/name: vault
    component: server
    vault-active: "true"
EOF

kubectl apply -f vault-node-port.yaml
