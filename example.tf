variable "region" {
  default = "us-west-2"
}

variable "project_name" {
  default = "example"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "ubuntu_1804_ami" {
  type = "map"
  default = {
    "us-west-2" = "ami-06f2f779464715dc5"
    "us-east-1" = ""
  }
}

provider "aws" {
  profile    = "default"
  region     = var.region
}

resource "aws_vpc" "vpc_0" {
  cidr_block = var.vpc_cidr
  enable_dns_hostnames = true
  name = var.project_name

  tags = {
    Name = var.project_name
  }

}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.(var.project_name).id}"
}

resource "aws_subnet" "example_subnet_a" {
  vpc_id = "${aws_vpc.example_vpc.id}"
  cidr_block = "10.100.1.0/24"
  availability_zone = "us-west-2a"

  tags = {
    Name = "example"
  }

}

resource "aws_subnet" "example_subnet_b" {
  vpc_id = "${aws_vpc.example_vpc.id}"
  cidr_block = "10.100.2.0/24"
  availability_zone = "us-west-2b"

  tags = {
    Name = "example_1"
  }

}

resource "aws_instance" "kubemaster_0" {
  ami           = var.amis[var.region]
  instance_type = "t2.micro"
  subnet_id = "${aws_subnet.example_subnet_a.id}"

  tags = {
    Name = "example"
  }

}

resource "aws_instance" "kubemaster_1" {
  ami           = var.amis[var.region]
  instance_type = "t2.micro"
  subnet_id = "${aws_subnet.example_subnet_b.id}"

  tags = {
    Name = "example_1"
  }

}

resource "aws_eip" "example_eip" {
  vpc = true
  instance = "${aws_instance.kubemaster_0.id}"

  tags = {
    Name = "example"
  }

  provisioner "local-exec" {
    command = "echo ${aws_eip.example_eip.public_ip} > kubemaster_0.public_ip.txt"
  }

}

resource "aws_eip" "example_1_eip" {
  vpc = true
  instance = "${aws_instance.kubemaster_1.id}"

  tags = {
    Name = "example_1"
  }

  provisioner "local-exec" {
    command = "echo ${aws_eip.example_1_eip.public_ip} > kubemaster_1.public_ip.txt"
  }

}
