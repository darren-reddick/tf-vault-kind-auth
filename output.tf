output "vault-server-connect" {
    description = "SSM Connect to the vault server"
    value = "aws ssm start-session --target ${aws_instance.vault_server.id}"
}

output "vault-k8s-client-connect" {
    description = "SSM Connect to the vault k8s client"
    value = "aws ssm start-session --target ${aws_instance.vault_k8s_client.id}"
}

output "vault-server-address" {
    description = "The vault server address"
    value = "http://${aws_instance.vault_server.private_dns}:8200"
}