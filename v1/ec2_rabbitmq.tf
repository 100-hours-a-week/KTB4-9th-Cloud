data "aws_security_group" "rabbitmq_main" {
  name   = "${var.project_name}-sg"
  vpc_id = aws_vpc.main.id
}

data "aws_security_group" "rabbitmq_judger" {
  name   = "${var.project_name}-judger-sg"
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "rabbitmq_sg" {
  name        = "${var.project_name}-rabbitmq-sg"
  description = "Security group for the dedicated RabbitMQ server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow AMQP from the main application server"
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    security_groups = [
      data.aws_security_group.rabbitmq_main.id,
      data.aws_security_group.rabbitmq_judger.id,
    ]
  }

  ingress {
    description     = "Allow SSH through the main application server"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [data.aws_security_group.rabbitmq_main.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rabbitmq-sg"
  }
}

resource "aws_instance" "rabbitmq_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.rabbitmq_sg.id]
  key_name                    = var.key_name
  disable_api_termination     = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              apt-get update -y
              apt-get install -y curl git
              curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
              sh /tmp/get-docker.sh
              usermod -aG docker ubuntu
              systemctl enable docker
              systemctl start docker
              EOF

  lifecycle {
    ignore_changes  = [ami]
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-rabbitmq-server"
  }
}
