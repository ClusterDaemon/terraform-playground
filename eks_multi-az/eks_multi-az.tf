# Terraform config for the SDC2019 conference. This will establish an EKS cluster in AWS with an auto-scaling worker pool, providing the wielder with a valid kubectl config.
#
# I'll freshen this up later and make it more vairable / dynamic. For the purposes of this demo, it's more than good enough.
#
# A lot of this is just cobblework for EKS - we neeed a functioning VPC for it to chill in and a few policies defined.

variable "region" {
  default = "us-west-2"
  type = string
}

variable "cluster-name" {
  default = "sdc2019-demo"
  type    = string
}

variable "kubectl-cidr" {
  default = ["0.0.0.0/32"]
  type = list
}

variable "worker_instance_type" {
  default = "m4.large"
  type = string
}

variable "linstor_sp_size" {
  default = 100
  type = number
}

variable "pem_key" {
  default = "sdc2019-demo"
  type = string
}

variable "worker_node_count" {
  default = 3
  type = number
}

provider "aws" {
  profile = "default"
  region = var.region
}

data "aws_availability_zones" "available" {}

resource "aws_vpc" "demo" {
  cidr_block = "10.1.0.0/16"

  tags = "${
    map(
     "Name", "sdc2019-demo-node",
     "kubernetes.io/cluster/${var.cluster-name}", "shared",
    )
  }"
}

resource "aws_subnet" "demo" {
  count = 3

  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  cidr_block        = "10.1.${count.index}.0/24"
  vpc_id            = "${aws_vpc.demo.id}"

  tags = "${
    map(
     "Name", "sdc2019-demo",
     "kubernetes.io/cluster/${var.cluster-name}", "shared",
    )
  }"
}

resource "aws_internet_gateway" "demo" {
  vpc_id = "${aws_vpc.demo.id}"

  tags = {
    Name = "sdc2019-demo"
  }
}

resource "aws_route_table" "demo" {
  vpc_id = "${aws_vpc.demo.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.demo.id}"
  }
}

resource "aws_route_table_association" "demo" {
  count = 3

  subnet_id      = "${aws_subnet.demo.*.id[count.index]}"
  route_table_id = "${aws_route_table.demo.id}"
}

# We need IAM policy configuration to allow EKS to grab data from other AWS services.

resource "aws_iam_role" "demo-cluster" {
  name = "sdc2019-demo-cluster"

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

resource "aws_iam_role_policy_attachment" "demo-cluster-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = "${aws_iam_role.demo-cluster.name}"
}

resource "aws_iam_role_policy_attachment" "demo-cluster-AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = "${aws_iam_role.demo-cluster.name}"
}

# Security groups to control access to K8S masters

resource "aws_security_group" "demo-cluster" {
  name        = "SDC2019-demo-cluster"
  description = "Cluster communication with worker nodes"
  vpc_id      = "${aws_vpc.demo.id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SDC2019-demo"
  }
}

# Define what addresses may access kubectl

resource "aws_security_group_rule" "demo-cluster-ingress-workstation-https" {
  cidr_blocks       = var.kubectl-cidr
  description       = "Allow workstation to communicate with the cluster API Server"
  from_port         = 443
  protocol          = "tcp"
  security_group_id = "${aws_security_group.demo-cluster.id}"
  to_port           = 443
  type              = "ingress"
}

# The actual K8S master cluster.
# I would rather use an expression to reference any number of subnet_ids
# but I have no idea why a splat expression isn't working
# so I hard-coded the list of indexed resources like a chump.

resource "aws_eks_cluster" "demo" {
  name            = "${var.cluster-name}"
  role_arn        = "${aws_iam_role.demo-cluster.arn}"
  version         = "1.14"

  vpc_config {
    security_group_ids = ["${aws_security_group.demo-cluster.id}"]
    subnet_ids         = ["${aws_subnet.demo[0].id}","${aws_subnet.demo[1].id}","${aws_subnet.demo[2].id}"]
  }

  depends_on = [
    "aws_iam_role_policy_attachment.demo-cluster-AmazonEKSClusterPolicy",
    "aws_iam_role_policy_attachment.demo-cluster-AmazonEKSServicePolicy",
  ]
}

# You'll want to get to kubectl at this point.
# The AWS CLI "eks update-kubeconfig" command provides a simple method to create or update configuration files.
# However, the configuration below should spit a valid kubectl config at you on apply or query to use as you will.

locals {
  kubeconfig = <<KUBECONFIG


apiVersion: v1
clusters:
- cluster:
    server: ${aws_eks_cluster.demo.endpoint}
    certificate-authority-data: ${aws_eks_cluster.demo.certificate_authority.0.data}
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
        - "${var.cluster-name}"
KUBECONFIG
}

output "kubeconfig" {
  value = "${local.kubeconfig}"
}

# Worker node IAM policies

resource "aws_iam_role" "demo-node" {
  name = "sdc2019-demo-node"

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

resource "aws_iam_role_policy_attachment" "demo-node-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = "${aws_iam_role.demo-node.name}"
}

resource "aws_iam_role_policy_attachment" "demo-node-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = "${aws_iam_role.demo-node.name}"
}

resource "aws_iam_role_policy_attachment" "demo-node-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = "${aws_iam_role.demo-node.name}"
}

resource "aws_iam_instance_profile" "demo-node" {
  name = "sdc2019-demo"
  role = "${aws_iam_role.demo-node.name}"
}

resource "aws_iam_openid_connect_provider" "demo" {
  client_id_list        = ["sts.amazonaws.com"]
  thumbprint_list       = []
  url                   = "${aws_eks_cluster.demo.identity.0.oidc.0.issuer}"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "demo_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.demo.url, "https://", "")}:sub"
      values = ["system:serviceaccount:kube-system:aws-node"]
    }

    principals {
      identifiers =["${aws_iam_openid_connect_provider.demo.arn}"]
      type = "Federated"
    }
  }
}

resource "aws_iam_role" "demo-node-sa-role" {
  assume_role_policy = "${data.aws_iam_policy_document.demo_assume_role_policy.json}"
  name = "demo-node-sa-role"
}

# Worker node security groups

resource "aws_security_group" "demo-node" {
  name        = "sdc2019-demo-node"
  description = "Security group for all nodes in the cluster"
  vpc_id      = "${aws_vpc.demo.id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${
    map(
     "Name", "sdc2019-demo-node",
     "kubernetes.io/cluster/${var.cluster-name}", "owned",
    )
  }"
}

resource "aws_security_group_rule" "demo-node-ingress-self" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = "${aws_security_group.demo-node.id}"
  source_security_group_id = "${aws_security_group.demo-node.id}"
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "demo-node-ingress-cluster" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.demo-node.id}"
  source_security_group_id = "${aws_security_group.demo-cluster.id}"
  to_port                  = 65535
  type                     = "ingress"
}

# Worker node access to EKS master cluster

resource "aws_security_group_rule" "demo-cluster-ingress-node-https" {
  description              = "Allow pods to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.demo-cluster.id}"
  source_security_group_id = "${aws_security_group.demo-node.id}"
  to_port                  = 443
  type                     = "ingress"
}

# Worker node auto-scaling EKS-friendly AMI definition

data "aws_ami" "eks-worker" {
  filter {
    name   = "name"
    values = ["amazon-eks-node-${aws_eks_cluster.demo.version}-v*"]
  }

  most_recent = true
  owners      = ["602401143452"] # Amazon EKS AMI Account ID
}

# Worker node auto-scaling launch configuration

data "aws_region" "current" {}

# Insert necessary bootstrap commands into worker node userdata
locals {
  demo-node-userdata = <<USERDATA
#!/bin/bash
set -o xtrace
/etc/eks/bootstrap.sh --apiserver-endpoint '${aws_eks_cluster.demo.endpoint}' --b64-cluster-ca '${aws_eks_cluster.demo.certificate_authority.0.data}' '${var.cluster-name}'
vgcreate vg0 /dev/sdb
lvcreate -T -l 100%FREE -n thin-lvm vg0
yum -y install kernel-headers-$(uname -r)
USERDATA
}

resource "aws_launch_configuration" "demo" {
  associate_public_ip_address = true
  iam_instance_profile        = "${aws_iam_instance_profile.demo-node.name}"
  image_id                    = "${data.aws_ami.eks-worker.id}"
  instance_type               = var.worker_instance_type
  key_name                    = var.pem_key
  name_prefix                 = "sdc2019-demo"
  security_groups             = ["${aws_security_group.demo-node.id}"]
  user_data_base64            = "${base64encode(local.demo-node-userdata)}"

  ebs_block_device {
    device_name = "/dev/sdb"
    volume_size = var.linstor_sp_size
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Worker node auto-scaling group itself

resource "aws_autoscaling_group" "demo" {
  desired_capacity     = var.worker_node_count
  launch_configuration = "${aws_launch_configuration.demo.id}"
  max_size             = var.worker_node_count
  min_size             = 1
  name                 = "sdc2019-demo"
  vpc_zone_identifier  = ["${aws_subnet.demo[0].id}","${aws_subnet.demo[1].id}","${aws_subnet.demo[2].id}",]

  tag {
    key                 = "Name"
    value               = "sdc2019-demo"
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster-name}"
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
    - rolearn: ${aws_iam_role.demo-node.arn}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
CONFIGMAPAWSAUTH
}

output "config_map_aws_auth" {
  value = "${local.config_map_aws_auth}"
}
