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
        period=300s
    ```

1. Enable aws secrets engine
    ```
    vault secrets enable aws
    ```

1. Create an aws vault role to read dynamodb database
    ```
    vault write aws/roles/read-dynamo-role \
        credential_type=iam_user \
        policy_document=-<<EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": "dynamodb:*",
          "Resource": "*"
        }
      ]
    }
    EOF
    ```

1. Create vault-auth policy to use dynamo role
    ```
    vault policy write kube-auth - << EOF
    path "aws/creds/read-dynamo-role" {
    capabilities = ["read"]
    }
    EOF
    ```

## Testing Authentication by serviceaccount

1. Read the **vault-auth** serviceaccount token and use it to authenticate to the vault server
    ```
    cat << 'EOF' > entrypoint.sh
    #!/bin/bash

    log() {
        echo "$(date): $1"
    }

    [ -z "${VAULT_ADDR}" ] && { echo "Missing VAULT_ADDR env var"; exit 1; }
    [ -z "${ROLE}" ] && { echo "Missing ROLE env var"; exit 1; }
    [ -z "${TABLE_NAME}" ] && { echo "Missing TABLE_NAME env var"; exit 1; }

    log "Fetching serviceaccount token"
    TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

    log "Using K8S serviceaccount JWT to login to vault"
    AUTH=$(curl -sS --request POST --data '{"jwt": "'"${TOKEN}"'", "role": "'"${ROLE}"'"}' "${VAULT_ADDR}"/v1/auth/kubernetes/login)

    log "Extracting client_token"
    CLIENT_TOKEN=$(echo "${AUTH}" | jq -r '.auth.client_token')

    log "Requesting dynamo read credentials"
    CREDS=$(curl -sS -H "X-Vault-Request: true" -H "X-Vault-Token: ${CLIENT_TOKEN}" "${VAULT_ADDR}"/v1/aws/creds/read-dynamo-role)

    export AWS_ACCESS_KEY_ID=$(jq -r '.data.access_key' <<< "${CREDS}")
    export AWS_SECRET_ACCESS_KEY=$(jq -r '.data.secret_key' <<< "${CREDS}")

    log "Sleeping to let creds become consistent"
    sleep 10

    log "Reading item from dynamodb table"
    aws dynamodb get-item --table-name "${TABLE_NAME}" --key '{"userid": {"S": "1234"}}'

    EOF

    chmod u+x entrypoint.sh
    ```

1. Create the Dockerfile for the test image
    ```
    cat << EOF > Dockerfile
    FROM amazon/aws-cli:latest

    RUN yum update -y \
      && yum install -y jq \
      && yum clean all

    COPY entrypoint.sh /usr/local/bin/entrypoint.sh
    ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

    EOF
    ```

1. Build the docker image for testing
    ```
    docker build -t vault-auth-tester .
    ```

1. Load the image into the kind cluster
    ```
    kind load docker-image vault-auth-tester:latest
    ```

1. Run the test container in a pod using the **vault-auth** serviceaccount
    ```
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: Pod
    metadata:
      name: vault-auth-tester
    spec:
      serviceAccountName: vault-auth
      containers:
      - name: vault-auth-tester
        image: vault-auth-tester:latest
        imagePullPolicy: Never
        env:
          - name: ROLE
            value: demo
          - name: VAULT_ADDR
            value: ${VAULT_ADDR}
          - name: TABLE_NAME
            value: vault-auth-Table
    EOF
    ```

1. View the pod logs which should show an item being fetched from the dynamodb table (see aws_dynamodb_table_item resource in dynamo.tf file)
    ```
    kubectl logs vault-auth-tester
    ```
