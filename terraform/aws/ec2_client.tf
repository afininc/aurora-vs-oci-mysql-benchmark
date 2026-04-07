resource "aws_instance" "benchmark_client" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "c6i.4xlarge"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.client.id]
  key_name                    = aws_key_pair.benchmark.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 100
    delete_on_termination = true
  }

  tags = {
    Name = "aurora-benchmark-client"
  }
}
