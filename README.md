## Root token

Once the userdata script has run vault should be ready and the root token should be available in a local file (terrible security but its a demo)

1. Start an SSH session via ssm to the vault-server (see terraform **vault-server-connect** output)
1. Watch kubectl pod status until all of the vault pods go into ready status
    ```
    sudo kubectl get po -w
    ```
1. Fetch the root token from the **init.json** file in roots home and save this somewhere locally
    ```
    sudo cat /root/init.json
    ```

## Kubernetes and Vault Admin

1. Start an ssh session via ssm to the vault-k8s-client (see terraform **vault-k8s-client-connect** output)
1. Create K8S RBAC resources for vault authentication. The **vault-reviewer** account will be used by vault to validate requests for secrets from pods in the client cluster - for this it requires the **system:auth-delegator** ClusterRole
    ```
    cat << EOF | sudo kubectl apply -f -
    ---
    # create the vault reviewer account to verify tokens
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: vault-reviewer

    ---
    # bind reviewer account to the auth-delegator role
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: role-tokenreview-binding
      namespace: default
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: system:auth-delegator
    subjects:
    - kind: ServiceAccount
      name: vault-reviewer
      namespace: default

    ---
    # create the vault account which will authenticate to vault
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: vault-auth
    EOF
    ```
1. Fetch the token for the **vault-reviewer** service account
    ```
    REVIEWER_TOKEN=$(sudo kubectl get secret \
    $(sudo kubectl get serviceaccount vault-reviewer \
    -o jsonpath={.secrets[0].name}) -o jsonpath={.data.token} | base64 -d -)
    ```
1. Fetch the API server address
    ```
    APISERVER=$(sudo kubectl config view -o jsonpath='{.clusters[*].cluster.server}')
    ```

1. Fetch the K8S cluster CA certificate and store in a file
    ```
    sudo kubectl get secrets -ojson | jq -r '.items[] | select(.metadata.name | startswith("default-token-")).data["ca.crt"]' | base64 -d - > ${HOME}/ca.crt
    ```

1. set the vault url (use the address from terraform output **vault-server-address**)
    ```
    export VAULT_ADDR=[http://address:8200]
    ```

1. Login to vault and provide the root token obtained in step 3 when prompted
    ```
    vault login
    ```

1. Enable the K8S auth method
    ```
    vault auth enable kubernetes
    ```

1. Configure the K8S auth method using the values obtained from K8S in previous steps 
    ```
    vault write auth/kubernetes/config \
        token_reviewer_jwt=${REVIEWER_TOKEN}  \
        kubernetes_host=${APISERVER} \
        kubernetes_ca_cert=@${HOME}/ca.crt
    ```

1. Create the **demo** role under K8S auth method linked to the **kube-auth** policy. This role will enable pods running under service account **vault-auth** in the **default** namespace (of the client cluster) to assume it
    ```
    vault write auth/kubernetes/role/demo \
        bound_service_account_names=vault-auth \
        bound_service_account_namespaces=default \
        policies=kube-auth \
        period=60s
    ```

1. Enable kv2 secrets engine
    ```
    vault secrets enable -path=secret kv-v2
    ```

1. Create **vault-auth** policy to read creds secret
    ```
    vault policy write kube-auth - << EOF
    path "secret/data/creds" {
    capabilities = ["read"]
    }
    EOF
    ```

1. Create the creds secret
    ```
    vault kv put secret/creds GREETING=Hello NAME=World
    ```

1. Check we can read it
    ```
    vault kv get secret/creds
    ```
## Testing Authentication by serviceaccount

1. Read the **vault-auth** serviceaccount token and use it to authenticate to the vault server
    ```
    AUTH=$(curl --request POST --data '{"jwt": "'$(sudo kubectl get secret \
    $(sudo kubectl get serviceaccount vault-auth \
    -o jsonpath={.secrets[0].name}) -o jsonpath={.data.token} | base64 -d -)'", "role": "demo"}' ${VAULT_ADDR}/v1/auth/kubernetes/login)
    ```

1. Verify that the authenticated user is using the **demo** role
    ```
    echo $AUTH | jq '.auth.metadata'
    ```

1. Extract the token from the response
    ```
    TOKEN=$(echo ${AUTH} | jq -r '.auth.client_token')
    ```

1. Use the token to fetch the creds secret using a raw curl so we can ensure we use the TOKEN for **vault-auth**
    ```
    curl -H "X-Vault-Request: true" -H "X-Vault-Token: ${TOKEN}" ${VAULT_ADDR}/v1/secret/data/creds | jq '.'
    ```
