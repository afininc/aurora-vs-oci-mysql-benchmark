resource "aws_security_group" "client" {
  name        = "aurora-benchmark-client-sg"
  description = "Benchmark client EC2 instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aurora-benchmark-client-sg"
  }
}

resource "aws_security_group" "aurora" {
  name        = "aurora-benchmark-aurora-sg"
  description = "Aurora MySQL cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from benchmark client"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.client.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aurora-benchmark-aurora-sg"
  }
}
