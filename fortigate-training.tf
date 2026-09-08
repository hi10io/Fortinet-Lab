terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "awscc" {
  region  = var.aws_region
  profile = var.aws_profile
}

variable "aws_region" {
  description = "AWS region in which to deploy the lab."
  type        = string
  default     = "ca-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profile used by both the AWS and AWS Cloud Control providers."
  type        = string
  default     = "dev"
}

variable "admin_cidr" {
  description = "Your public IP in CIDR notation, for example 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid restricted IPv4 CIDR and cannot be 0.0.0.0/0."
  }
}

variable "instance_type" {
  description = "EC2 instance type. c6i.large is a small Fortinet-supported training option."
  type        = string
  default     = "c6i.large"
}

variable "windows_instance_type" {
  description = "EC2 instance type for the Windows training desktop."
  type        = string
  default     = "t3.medium"
}

variable "name" {
  description = "Name prefix for the lab resources."
  type        = string
  default     = "fortigate-training"
}

resource "tls_private_key" "windows" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "windows" {
  key_name   = "${var.name}-windows"
  public_key = tls_private_key.windows.public_key_openssh

  tags = {
    Name = "${var.name}-windows"
  }
}

resource "local_sensitive_file" "windows_private_key" {
  content         = tls_private_key.windows.private_key_pem
  filename        = "${path.module}/${var.name}-windows.pem"
  file_permission = "0600"
}

# This selects the newest x86 PAYG FortiGate image available to the account in
# the chosen region. The AWS account must first accept the Marketplace terms.
data "aws_ami" "fortigate_payg" {
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = ["FortiGate-VM64-AWSONDEMAND *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Latest AWS-maintained Windows Server 2022 image with Desktop Experience.
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name}-vpc"
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.20.1.0/24"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.20.2.0/24"
  # A FortiGate instance can only attach ENIs from the same Availability Zone.
  # AWS selects the public subnet's AZ; the private subnet must match it.
  availability_zone       = aws_subnet.public.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = awscc_ec2_network_interface.port2.network_interface_id
  }

  tags = {
    Name = "${var.name}-private"
  }

  depends_on = [awscc_ec2_network_interface_attachment.port2]
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "fortigate" {
  name        = "${var.name}-management"
  description = "Restricted FortiGate training management access"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "FortiGate HTTPS management"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "RDP forwarded through FortiGate"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "FortiGate SSH management"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description      = "Allow FortiGate outbound access"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "${var.name}-management"
  }
}

resource "aws_security_group" "fortigate_internal" {
  name        = "${var.name}-internal"
  description = "Traffic from the private training subnet to FortiGate port2"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "Private subnet traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_subnet.private.cidr_block]
  }

  egress {
    description = "Allow FortiGate outbound access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-internal"
  }
}

resource "aws_security_group" "windows" {
  name        = "${var.name}-windows"
  description = "Windows desktop access through the FortiGate"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "RDP from FortiGate port2 after source NAT"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["10.20.2.10/32"]
  }

  egress {
    description = "Allow Windows outbound access through FortiGate"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-windows"
  }
}

resource "awscc_ec2_network_interface" "port1" {
  subnet_id         = aws_subnet.public.id
  private_ip_address = "10.20.1.10"
  group_set          = [aws_security_group.fortigate.id]
  source_dest_check  = false

  tags = [{
    key   = "Name"
    value = "${var.name}-port1"
  }]
}

resource "awscc_ec2_network_interface" "port2" {
  subnet_id          = aws_subnet.private.id
  private_ip_address = "10.20.2.10"
  group_set          = [aws_security_group.fortigate_internal.id]
  source_dest_check  = false

  tags = [{
    key   = "Name"
    value = "${var.name}-port2"
  }]
}

resource "aws_instance" "fortigate" {
  ami                         = data.aws_ami.fortigate_payg.id
  instance_type               = var.instance_type
  user_data_replace_on_change = true

  primary_network_interface {
    network_interface_id = awscc_ec2_network_interface.port1.network_interface_id
  }

  user_data = <<-FORTIOS
    config system interface
      edit "port1"
        set alias "WAN"
        set allowaccess ping https ssh
      next
      edit "port2"
        set alias "TRAINING-LAN"
        set allowaccess ping
      next
    end

    config firewall address
      edit "Windows-Desktop"
        set subnet 10.20.2.20 255.255.255.255
      next
    end

    config firewall vip
      edit "Windows-RDP"
        set extintf "port1"
        set extip 10.20.1.10
        set mappedip "10.20.2.20"
        set portforward enable
        set extport 3389
        set mappedport 3389
      next
    end

    config firewall policy
      edit 1
        set name "Training-LAN-to-Internet"
        set srcintf "port2"
        set dstintf "port1"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set nat enable
      next
      edit 2
        set name "RDP-to-Windows"
        set srcintf "port1"
        set dstintf "port2"
        set action accept
        set srcaddr "all"
        set dstaddr "Windows-RDP"
        set schedule "always"
        set service "RDP"
        set nat enable
      next
    end
  FORTIOS

  root_block_device {
    volume_type = "gp3"
    volume_size = 10
    encrypted   = true
  }

  # AWS provider 6.x currently detects instance-level source_dest_check drift
  # when a separately managed ENI is used as primary. The setting remains
  # enforced on both AWS Cloud Control network interface resources.
  lifecycle {
    ignore_changes = [source_dest_check]
  }

  tags = {
    Name = var.name
  }
}

resource "awscc_ec2_network_interface_attachment" "port2" {
  instance_id          = aws_instance.fortigate.id
  network_interface_id = awscc_ec2_network_interface.port2.network_interface_id
  device_index         = "1"
}

resource "aws_instance" "windows" {
  ami                         = data.aws_ami.windows.id
  instance_type               = var.windows_instance_type
  subnet_id                   = aws_subnet.private.id
  private_ip                  = "10.20.2.20"
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.windows.id]
  key_name                    = aws_key_pair.windows.key_name
  get_password_data           = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 40
    encrypted   = true
  }

  depends_on = [
    aws_instance.fortigate,
    awscc_ec2_network_interface_attachment.port2,
    aws_route_table_association.private,
  ]

  tags = {
    Name = "${var.name}-windows"
  }
}

resource "aws_eip" "fortigate" {
  domain            = "vpc"
  network_interface = awscc_ec2_network_interface.port1.network_interface_id

  depends_on = [aws_instance.fortigate]

  tags = {
    Name = "${var.name}-eip"
  }
}

output "fortigate_url" {
  description = "FortiGate management URL. Allow several minutes for first boot."
  value       = "https://${aws_eip.fortigate.public_ip}"
}

output "fortigate_username" {
  value = "admin"
}

output "initial_password" {
  description = "The default initial password is the EC2 instance ID. Change it at first login."
  value       = aws_instance.fortigate.id
}

output "selected_ami" {
  description = "PAYG FortiGate AMI selected by Terraform."
  value = {
    id   = data.aws_ami.fortigate_payg.id
    name = data.aws_ami.fortigate_payg.name
  }
}

output "windows_rdp_address" {
  description = "Connect with Remote Desktop. The FortiGate forwards TCP/3389 to the private Windows desktop."
  value       = "${aws_eip.fortigate.public_ip}:3389"
}

output "windows_username" {
  value = "Administrator"
}

output "windows_password" {
  description = "Decrypted Windows Administrator password. Display with: terraform output -raw windows_password"
  value       = rsadecrypt(aws_instance.windows.password_data, tls_private_key.windows.private_key_pem)
  sensitive   = true
}

output "windows_private_key_file" {
  description = "Local path of the generated RSA private key."
  value       = local_sensitive_file.windows_private_key.filename
}

output "windows_private_ip" {
  value = aws_instance.windows.private_ip
}

output "availability_zone" {
  description = "Availability Zone containing both lab subnets and all EC2 network interfaces."
  value       = aws_subnet.public.availability_zone
}

output "selected_windows_ami" {
  description = "AWS-maintained Windows Server AMI selected by Terraform."
  value = {
    id   = data.aws_ami.windows.id
    name = data.aws_ami.windows.name
  }
}
