provider "aws" {
  profile    = "default"
  region     = "us-west-2"
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

resource "aws_instance" "example_instance" {
  ami           = "ami-06f2f779464715dc5"
  instance_type = "t2.micro"
  subnet_id = "${aws_subnet.example_subnet_a.id}"

  tags = {
    Name = "example"
  }

}

resource "aws_instance" "example_1_instance" {
  ami = "ami-06f2f779464715dc5"
  instance_type = "t2.micro"
  subnet_id = "${aws_subnet.example_subnet_b.id}"

  tags = {
    Name = "example_1"
  }

}

resource "aws_eip" "example_eip" {
  vpc = true
  instance = "${aws_instance.example_instance.id}"

  tags = {
    Name = "example"
  }

  provisioner "local-exec" {
    command = "echo ${aws_eip.example_eip.public_ip} > example_instance.public_ip.txt"
  }

}

resource "aws_eip" "example_1_eip" {
  vpc = true
  instance = "${aws_instance.example_1_instance.id}"

  tags = {
    Name = "example_1"
  }

  provisioner "local-exec" {
    command = "echo ${aws_eip.example_1_eip.public_ip} > example_1_instance.public_ip.txt"
  }

}
