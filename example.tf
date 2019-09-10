provider "aws" {
  profile    = "default"
  region     = "us-west-2"
  tags = {
    Name = "example"
  }
}

resource "aws_vpc" "example_vpc" {
  cidr_block = "10.100.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "example"
  }
}

resource "aws_internet_gateway" "example_gw" {
  vpc_id = "${aws_vpc.example_vpc.id}"
}

resource "aws_subnet" "example_subnet_a" {
  vpc_id = "${aws_vpc.example_vpc.id}"
  cidr_block = "10.100.0.0/24"
  availability_zone = "us-west-2a"
  tags = {
    Name = "example"
  }
  depends_on = ["aws_internet_gateway.example_gw"]
}

resource "aws_instance" "example_instance" {
  ami           = "ami-b374d5a5"
  instance_type = "t2.micro"
  network_interface {
    network_interface_id = "${aws_network_interface.example_interface.id}"
    device_index = 0
  }
  tags = {
    Name = "example"
  }
}

resource "aws_network_interface" "example_interface" {
  subnet_id = "${aws_subnet.example_subnet_a.id}"
  private_ips = ["10.100.0.1"]
  tags = {
    Name = "example"
  }
}

resource "aws_eip" "ip" {
  vpc = true
  instance = "${aws_instance.example_instance.id}"
  tags = {
    Name = "example"
  }
  depends_on = ["aws_internet_gateway.example_gw"]
}
