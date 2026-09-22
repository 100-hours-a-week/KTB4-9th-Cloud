resource "aws_security_group" "main_sg" {
  name        = "${var.project_name}-sg"
  description = "Security group for main server"
  vpc_id      = aws_vpc.main.id

  # HTTP (80)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS (443)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH (22)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-main-sg"
  }
}

resource "aws_security_group" "judger_sg" {
  name        = "${var.project_name}-judger-sg"
  description = "Security group for judger server"
  vpc_id      = aws_vpc.main.id

  # Main 서버(main_sg)로부터의 Rails API 3000번 포트만 허용!
  ingress {
    description     = "Allow HTTP API from main server"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.main_sg.id]
  }

  # 외부 스웨거 및 웹 접근 허용 (80)
  ingress {
    description = "Allow HTTP for Swagger and web"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-judger-sg"
  }
}