
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "vault_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = module.vpc.private_subnets.0
  iam_instance_profile   = aws_iam_instance_profile.kind_nodes.name
  vpc_security_group_ids = [aws_security_group.kind_node_sg.id]
  user_data              = <<MEOF
${base64encode(local.vault_server_user_data)}
MEOF

  tags = {
    Name = "Vault-Server"
  }

  depends_on = [module.vpc.private_nat_gateway_route_ids]

}

locals {
  vault_server_user_data = <<MEOF
#!/usr/bin/env bash

cd ~
${templatefile("${path.module}/templates/install_kind.sh.tpl", {})}

# Create cluster
kind \
  create \
  cluster \
  --name kind-vault \
  --config kind.conf

${templatefile("${path.module}/templates/install_vault.sh.tpl", {})}
MEOF
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kind_nodes" {
  name               = "${local.prefix}-kind-nodes-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_instance_profile" "kind_nodes" {
  name = "${local.prefix}-kind-nodes"
  role = aws_iam_role.kind_nodes.name
}

resource "aws_iam_role_policy_attachment" "ssm_managed_core_attach" {
  role       = aws_iam_role.kind_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_security_group" "kind_node_sg" {
  name        = "${local.prefix}-kind-nodes"
  description = "Security group for kind nodes"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Allows outbound connections"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    #tfsec:ignore:aws-vpc-no-public-egress-sgr
    cidr_blocks = ["0.0.0.0/0"]
    #tfsec:ignore:aws-vpc-no-public-egress-sgr
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port = 6443
    to_port   = 6443
    protocol  = "TCP"
    self      = "true"
  }

  ingress {
    from_port = 8200
    to_port   = 8200
    protocol  = "TCP"
    self      = "true"
  }

  tags = {
    Name = "${local.prefix}_node_sg"
  }
}

resource "aws_instance" "vault_k8s_client" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = module.vpc.private_subnets.0
  iam_instance_profile   = aws_iam_instance_profile.kind_nodes.name
  vpc_security_group_ids = [aws_security_group.kind_node_sg.id]
  user_data              = <<MEOF
${base64encode(local.vault_k8s_client_user_data)}
MEOF

  tags = {
    Name = "Vault-K8S-Client"
  }

  depends_on = [module.vpc.private_nat_gateway_route_ids]
}

locals {
  vault_k8s_client_user_data = <<MEOF
#!/usr/bin/env bash

cd ~
${templatefile("${path.module}/templates/install_kind.sh.tpl", {})}

# Create K8S cluster
kind \
  create \
  cluster \
  --name kind \
  --config kind.conf

# install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# install vault (to use cli)
curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
apt-get update && apt-get install vault

MEOF
}

