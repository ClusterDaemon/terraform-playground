# Establishes an EKS cluster in AWS with an auto-scaling worker pool, providing the wielder with a valid kubectl config.
# Assumes that aws_cli is installed and configured with valid credentials
# Assumes that aws_iam_authenticator binary can be found via $PATH

variable "region" {
  default = "us-west-2"
  type = string
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
  type = string
}

variable "cluster_name" {
  default = "linbit-eks"
  type    = string
}

variable "kubectl_cidr" {
  default = ["0.0.0.0/32"]
  type = list
}

variable "worker_instance_type" {
  default = "m4.large"
  type = string
}

variable "worker_disk_size" {
  default = 100
  type = number
}

variable "pem_key" {
  default = "linbit_eks"
  type = string
}

variable "worker_node_count" {
  default = 3
  type = number
}

variable "worker_node_max_count" {
  default = 3
  type = number
}

variable "worker_node_min_count" {
  default = 1
  type = number
}

variable "kube_version" {
  default = 1.14
  type = number
}

provider "aws" {
  profile = "default"
  region = var.region
}

data "aws_availability_zones" "available" {}

resource "aws_vpc" "eks" {
  cidr_block = var.vpc_cidr

  tags = "${
    map(
     "Name", "${var.cluster_name}",
     "kubernetes.io/cluster/${var.cluster_name}", "shared",
    )
  }"
}

resource "aws_subnet" "eks" {
  count = 3

  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  cidr_block        = "${cidrsubnet((var.vpc_cidr), 8, count.index)}"
  vpc_id            = "${aws_vpc.eks.id}"

  tags = "${
    map(
     "Name", "${var.cluster_name}",
     "kubernetes.io/cluster/${var.cluster_name}", "shared",
    )
  }"
}

resource "aws_internet_gateway" "eks" {
  vpc_id = "${aws_vpc.eks.id}"

  tags = {
    Name = var.cluster_name
  }
}

resource "aws_route_table" "eks" {
  vpc_id = "${aws_vpc.eks.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.eks.id}"
  }
}

resource "aws_route_table_association" "eks" {
  count = 3

  subnet_id      = "${aws_subnet.eks.*.id[count.index]}"
  route_table_id = "${aws_route_table.eks.id}"
}

# We need IAM policy configuration to allow EKS to grab data from other AWS services.

resource "aws_iam_role" "eks" {
  name = var.cluster_name

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "eks-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = "${aws_iam_role.eks.name}"
}

resource "aws_iam_role_policy_attachment" "eks-AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = "${aws_iam_role.eks.name}"
}

resource "aws_security_group" "eks" {
  name        = var.cluster_name
  description = "Control access to K8S masters"
  vpc_id      = "${aws_vpc.eks.id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = var.cluster_name
  }
}

# Define what addresses may access kubectl

resource "aws_security_group_rule" "eks-ingress-workstation-https" {
  cidr_blocks       = var.kubectl_cidr
  description       = "Allow workstation to communicate with the cluster API Server"
  from_port         = 443
  protocol          = "tcp"
  security_group_id = "${aws_security_group.eks.id}"
  to_port           = 443
  type              = "ingress"
}

# The actual K8S master cluster.
# I would rather use an expression to reference any number of subnet_ids
# but I have no idea why a splat expression isn't working
# so I hard-coded the list of indexed resources like a chump.
# "${aws_subnet.eks[0].id}","${aws_subnet.eks[1].id}","${aws_subnet.eks[2].id}" 

resource "aws_eks_cluster" "eks" {
  name            = var.cluster_name
  role_arn        = "${aws_iam_role.eks.arn}"
  version         = var.kube_version

  vpc_config {
    security_group_ids = ["${aws_security_group.eks.id}"]
    subnet_ids         = ["${aws_subnet.eks[0].id}","${aws_subnet.eks[1].id}","${aws_subnet.eks[2].id}"]
  }

  depends_on = [
    "aws_iam_role_policy_attachment.eks-AmazonEKSClusterPolicy",
    "aws_iam_role_policy_attachment.eks-AmazonEKSServicePolicy",
  ]
}

# You'll want to get to kubectl at this point.
# The AWS CLI "eks update-kubeconfig" command provides a simple method to create or update configuration files.
# However, the configuration below should spit a valid kubectl config at you on apply or output to use as you will.

locals {
  kubeconfig = <<KUBECONFIG


apiVersion: v1
clusters:
- cluster:
    server: ${aws_eks_cluster.eks.endpoint}
    certificate-authority-data: ${aws_eks_cluster.eks.certificate_authority.0.data}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: aws
current-context: aws
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "${var.cluster_name}"
KUBECONFIG
}

output "kubeconfig" {
  value = "${local.kubeconfig}"
}

# Worker node IAM policies

resource "aws_iam_role" "eks_worker" {
  name = "eks_worker"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "eks_worker-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = "${aws_iam_role.eks_worker.name}"
}

resource "aws_iam_role_policy_attachment" "eks_worker-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = "${aws_iam_role.eks_worker.name}"
}

resource "aws_iam_role_policy_attachment" "eks_worker-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = "${aws_iam_role.eks_worker.name}"
}

resource "aws_iam_instance_profile" "eks_worker" {
  name = "eks_worker"
  role = "${aws_iam_role.eks_worker.name}"
}

# Worker node security groups

resource "aws_security_group" "eks_nodes" {
  name        = "eks_nodes"
  description = "Security group for all nodes in the cluster"
  vpc_id      = "${aws_vpc.eks.id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${
    map(
     "Name", "eks_nodes",
     "kubernetes.io/cluster/${var.cluster_name}", "owned",
    )
  }"
}

resource "aws_security_group_rule" "eks_nodes-ingress_self" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = "${aws_security_group.eks_nodes.id}"
  source_security_group_id = "${aws_security_group.eks_nodes.id}"
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "eks_nodes-ingress_cluster" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.eks_nodes.id}"
  source_security_group_id = "${aws_security_group.eks.id}"
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "eks-ingress-eks_nodes-https" {
  description              = "Allow pods to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.eks.id}"
  source_security_group_id = "${aws_security_group.eks_nodes.id}"
  to_port                  = 443
  type                     = "ingress"
}

# Worker node EKS-friendly AMI definition (Amazon Linux)

data "aws_ami" "eks_worker" {
  filter {
    name   = "name"
    values = ["amazon-eks-node-${aws_eks_cluster.eks.version}-v*"]
  }

  most_recent = true
  owners      = ["602401143452"] # Amazon EKS AMI Account ID
}

data "aws_region" "current" {}

# Insert necessary bootstrap commands into worker node userdata
locals {
  eks-worker-userdata = <<USERDATA
#!/bin/bash
set -o xtrace
/etc/eks/bootstrap.sh --apiserver-endpoint '${aws_eks_cluster.eks.endpoint}' --b64-cluster-ca '${aws_eks_cluster.eks.certificate_authority.0.data}' '${var.cluster_name}'
vgcreate vg0 /dev/sdb
lvcreate -T -l 100%FREE -n thin-lvm vg0
yum -y install kernel-headers-$(uname -r)
USERDATA
}

resource "aws_launch_configuration" "eks_worker" {
  associate_public_ip_address = true
  iam_instance_profile        = "${aws_iam_instance_profile.eks_worker.name}"
  image_id                    = "${data.aws_ami.eks_worker.id}"
  instance_type               = var.worker_instance_type
  key_name                    = var.pem_key
  name_prefix                 = "eks"
  security_groups             = ["${aws_security_group.eks_nodes.id}"]
  user_data_base64            = "${base64encode(local.eks-worker-userdata)}"

  ebs_block_device {
    device_name = "/dev/sdb"
    volume_size = var.worker_disk_size
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Worker node auto-scaling group itself

resource "aws_autoscaling_group" "eks_nodes" {
  desired_capacity     = var.worker_node_count
  launch_configuration = "${aws_launch_configuration.eks_worker.id}"
  max_size             = var.worker_node_max_count
  min_size             = var.worker_node_min_count
  name                 = var.cluster_name
  vpc_zone_identifier  = ["${aws_subnet.eks[0].id}","${aws_subnet.eks[1].id}","${aws_subnet.eks[2].id}",]

  tag {
    key                 = "Name"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }
}


# This should be unnecessary after adding the new SA IAM role feature
# You'll need to 'kubectl apply -f' this IAM role ConfigMap in order to configure the cluster to allow our custom worker nodes to join.
# Run 'terraform output config_map_aws_auth' to print the necessary ConfigMap.
#
locals {
  config_map_aws_auth = <<CONFIGMAPAWSAUTH


apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${aws_iam_role.eks_worker.arn}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
CONFIGMAPAWSAUTH
}

output "config_map_aws_auth" {
  value = "${local.config_map_aws_auth}"
}
