resource "aws_instance" "judge_server" {
  ami           = data.aws_ami.ubuntu.id # Amazon Linux 2 AMI (HVM), SSD Volume Type
  instance_type = "c7i-flex.large"
  subnet_id     = aws_subnet.public.id
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.judger_sg.id]

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
                #!/bin/bash
                apt-get update -y
                apt-get install -y curl git
                curl -fsSL https://get.docker.com -o get-docker.sh
                sh get-docker.sh
                usermod -aG docker ubuntu
                systemctl enable docker
                systemctl start docker
                EOF

  tags = {
    Name = "${var.project_name}-judger-instance"
  }
}