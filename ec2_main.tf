data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "main_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.main_sg.id]
  key_name               = var.key_name # Replace with your key pair name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-main-server"
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y curl git
              
              # 공식 Docker 원클릭 설치 스크립트 (Docker 엔진 + Compose 플러그인 자동 설치)
              curl -fsSL https://get.docker.com -o get-docker.sh
              sh get-docker.sh
              
              # ubuntu 기본 계정에 도커 실행 권한 부여
              usermod -aG docker ubuntu
              systemctl enable docker
              systemctl start docker
              EOF

}