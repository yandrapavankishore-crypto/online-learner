
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "online-learning-devops"
      ManagedBy = "Terraform"
    }
  }
}

# ------------------------------------------
# VARIABLES
# ------------------------------------------

variable "controller_instance_id" {
  description = "Existing Control Node EC2 instance ID"
  type        = string
}

variable "key_name" {
  description = "Existing EC2 SSH key pair"
  type        = string
}

variable "admin_cidr" {
  description = "Your trusted public IPv4 CIDR"
  type        = string
}

# ------------------------------------------
# EXISTING CONTROL NODE NETWORK
# ------------------------------------------

data "aws_instance" "controller" {
  instance_id = var.controller_instance_id
}

data "aws_subnet" "controller" {
  id = data.aws_instance.controller.subnet_id
}

locals {
  vpc_id    = data.aws_subnet.controller.vpc_id
  subnet_id = data.aws_instance.controller.subnet_id

  # Fixed private addresses in the controller subnet.
  # Check that offsets 210-213 are available before apply.
  node_ips = {
    master   = cidrhost(data.aws_subnet.controller.cidr_block, 210)
    worker1  = cidrhost(data.aws_subnet.controller.cidr_block, 211)
    worker2  = cidrhost(data.aws_subnet.controller.cidr_block, 212)
    postgres = cidrhost(data.aws_subnet.controller.cidr_block, 213)
  }

  nodes = {
    master = {
      name = "k8s-control-plane"
      type = "t3.medium"
      disk = 25
      role = "kubernetes-control-plane"
      sg   = "kubernetes"
    }

    worker1 = {
      name = "k8s-worker-1"
      type = "t3.small"
      disk = 25
      role = "kubernetes-worker"
      sg   = "kubernetes"
    }

    worker2 = {
      name = "k8s-worker-2"
      type = "t3.small"
      disk = 25
      role = "kubernetes-worker"
      sg   = "kubernetes"
    }

    postgres = {
      name = "postgres-db"
      type = "t3.micro"
      disk = 20
      role = "database"
      sg   = "database"
    }
  }
}

# ------------------------------------------
# UBUNTU 24.04 AMI
# ------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ------------------------------------------
# KUBERNETES SECURITY GROUP
# ------------------------------------------

resource "aws_security_group" "kubernetes" {
  name_prefix = "learning-k8s-"
  description = "Kubernetes cluster security group"
  vpc_id      = local.vpc_id

  tags = {
    Name = "learning-k8s-sg"
  }
}

# All traffic between Kubernetes nodes
resource "aws_vpc_security_group_ingress_rule" "k8s_internal" {
  security_group_id            = aws_security_group.kubernetes.id
  referenced_security_group_id = aws_security_group.kubernetes.id
  ip_protocol                  = "-1"
  description                  = "Internal Kubernetes traffic"
}

# SSH from Control Node private IP
resource "aws_vpc_security_group_ingress_rule" "k8s_ssh" {
  security_group_id = aws_security_group.kubernetes.id
  cidr_ipv4         = "${data.aws_instance.controller.private_ip}/32"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from Ansible Control Node"
}

# Kubernetes API access from Control Node
resource "aws_vpc_security_group_ingress_rule" "k8s_api" {
  security_group_id = aws_security_group.kubernetes.id
  cidr_ipv4         = "${data.aws_instance.controller.private_ip}/32"
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "Kubernetes API from Control Node"
}

# Application NodePort for testing
resource "aws_vpc_security_group_ingress_rule" "k8s_nodeport" {
  security_group_id = aws_security_group.kubernetes.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 30080
  to_port           = 30080
  ip_protocol       = "tcp"
  description       = "Learning application NodePort"
}

resource "aws_vpc_security_group_egress_rule" "k8s_egress" {
  security_group_id = aws_security_group.kubernetes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------
# DATABASE SECURITY GROUP
# ------------------------------------------

resource "aws_security_group" "database" {
  name_prefix = "learning-db-"
  description = "PostgreSQL database security group"
  vpc_id      = local.vpc_id

  tags = {
    Name = "learning-database-sg"
  }
}

# SSH from Ansible Control Node
resource "aws_vpc_security_group_ingress_rule" "db_ssh" {
  security_group_id = aws_security_group.database.id
  cidr_ipv4         = "${data.aws_instance.controller.private_ip}/32"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from Control Node"
}

# PostgreSQL access from Kubernetes nodes
resource "aws_vpc_security_group_ingress_rule" "db_postgres" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.kubernetes.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from Kubernetes nodes"
}

resource "aws_vpc_security_group_egress_rule" "db_egress" {
  security_group_id = aws_security_group.database.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------
# EC2 INSTANCES
# ------------------------------------------

resource "aws_instance" "nodes" {
  for_each = local.nodes

  ami           = data.aws_ami.ubuntu.id
  instance_type = each.value.type
  key_name      = var.key_name

  subnet_id  = local.subnet_id
  private_ip = local.node_ips[each.key]

  # Public IPs are for internet connectivity in this lab.
  # Ansible uses private IPs only.
  associate_public_ip_address = true

  vpc_security_group_ids = [
    each.value.sg == "kubernetes"
    ? aws_security_group.kubernetes.id
    : aws_security_group.database.id
  ]

  root_block_device {
    volume_size = each.value.disk
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = each.value.name
    Role = each.value.role
  }
}

# ------------------------------------------
# AUTOMATIC ANSIBLE INVENTORY
# ------------------------------------------

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"

  content = <<-EOT
[k8s_master]
master ansible_host=${aws_instance.nodes["master"].private_ip} private_ip=${aws_instance.nodes["master"].private_ip}

[k8s_workers]
worker1 ansible_host=${aws_instance.nodes["worker1"].private_ip} private_ip=${aws_instance.nodes["worker1"].private_ip}
worker2 ansible_host=${aws_instance.nodes["worker2"].private_ip} private_ip=${aws_instance.nodes["worker2"].private_ip}

[database]
postgres ansible_host=${aws_instance.nodes["postgres"].private_ip} private_ip=${aws_instance.nodes["postgres"].private_ip}

[kubernetes:children]
k8s_master
k8s_workers

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=/home/ubuntu/.ssh/controllerAWS.pem
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
EOT
}

# ------------------------------------------
# OUTPUTS
# ------------------------------------------

output "vpc_id" {
  value = local.vpc_id
}

output "subnet_id" {
  value = local.subnet_id
}

output "private_ips" {
  value = {
    for name, instance in aws_instance.nodes :
    name => instance.private_ip
  }
}

output "public_ips" {
  value = {
    for name, instance in aws_instance.nodes :
    name => instance.public_ip
  }
}

output "instance_ids" {
  value = {
    for name, instance in aws_instance.nodes :
    name => instance.id
  }
}

output "ansible_inventory_path" {
  value = local_file.ansible_inventory.filename
}
