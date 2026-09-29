# -------------------------------------------------------------
# COSMOS 부하테스트 러너 전용 EC2 인스턴스 및 보안 그룹
# -------------------------------------------------------------

# 부하 발생기 전용 보안 그룹
resource "aws_security_group" "loadtest_sg" {
  name        = "${var.project_name}-loadtest-sg"
  description = "Security group for k6 loadtest runner"
  vpc_id      = aws_vpc.main.id

  # SSH 접속 허용 (22)
  ingress {
    description = "Allow SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 아웃바운드 전체 허용 (메인 서버 대상 HTTP/HTTPS 부하 인입 및 패키지 설치)
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-loadtest-sg"
  }
}

# 부하테스트 러너 EC2 인스턴스 (t3.medium: 2 vCPU, 4GB RAM)
resource "aws_instance" "loadtest_runner" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.loadtest_sg.id]
  key_name               = var.key_name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # [중요 안전장치] AMI 패치로 인한 인스턴스 불시 재생성(Destroy & Recreate) 방지
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.project_name}-loadtest-runner"
  }

  # k6 및 필수 시스템 튜닝 자동 프로비저닝 스크립트
  user_data = <<-EOF
              #!/bin/bash
              set -e

              # 1. 시스템 기본 패키지 업데이트 및 설치
              export DEBIAN_FRONTEND=noninteractive
              apt-get update -y
              apt-get install -y curl wget git jq htop unzip gnupg ca-certificates

              # 2. k6 공식 패키지 저장소 등록 및 설치
              gpg -k
              gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D34EE24C
              echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | tee /etc/apt/sources.list.d/k6.list
              apt-get update -y
              apt-get install -y k6

              # 3. Node.js (v20 LTS) 설치 (k6 보조 스크립트 실행용)
              curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
              apt-get install -y nodejs

              # 4. [인프라 튜닝] 대규모 부하 발생 시 소켓 고갈 방지를 위한 OS 커널 파라미터 상향
              cat << 'LIMITS' >> /etc/security/limits.conf
              * soft nofile 65535
              * hard nofile 65535
              ubuntu soft nofile 65535
              ubuntu hard nofile 65535
              root soft nofile 65535
              root hard nofile 65535
              LIMITS

              cat << 'SYSCTL' >> /etc/sysctl.d/99-k6-tuning.conf
              fs.file-max = 2097152
              net.ipv4.ip_local_port_range = 1024 65535
              net.ipv4.tcp_tw_reuse = 1
              net.core.somaxconn = 65535
              SYSCTL

              sysctl --system

              echo "k6 부하테스트 러너 환경 구성 완료" > /var/log/k6-init-complete.log
              EOF
}
