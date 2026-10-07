resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# AlmaLinux 9 (not 10): Rancher publishes k3s-selinux only up to EL9.
data "aws_ami" "almalinux" {
  most_recent = true
  owners      = ["764336703387"] # AlmaLinux OS Foundation

  filter {
    name   = "name"
    values = ["AlmaLinux OS 9.*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_eip" "server" {
  domain = "vpc"

  tags = { Name = "${var.cluster_name}-server" }
}

locals {
  instance_common = {
    ami                    = data.aws_ami.almalinux.id
    instance_type          = var.instance_type
    subnet_id              = aws_subnet.public.id
    vpc_security_group_ids = [aws_security_group.nodes.id]
    iam_instance_profile   = aws_iam_instance_profile.node.name
    key_name               = aws_key_pair.this.key_name
  }
}

resource "aws_instance" "server" {
  ami                    = local.instance_common.ami
  instance_type          = local.instance_common.instance_type
  subnet_id              = local.instance_common.subnet_id
  vpc_security_group_ids = local.instance_common.vpc_security_group_ids
  iam_instance_profile   = local.instance_common.iam_instance_profile
  key_name               = local.instance_common.key_name

  user_data = templatefile("${path.module}/templates/server.sh.tftpl", {
    k3s_version  = var.k3s_version
    k3s_token    = random_password.k3s_token.result
    public_ip    = aws_eip.server.public_ip
    cluster_name = var.cluster_name
    region       = var.region
  })

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = { Name = "${var.cluster_name}-server", Role = "server" }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "server" {
  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.server.id
}

resource "aws_instance" "agent" {
  count = var.agent_count

  ami                    = local.instance_common.ami
  instance_type          = local.instance_common.instance_type
  subnet_id              = local.instance_common.subnet_id
  vpc_security_group_ids = local.instance_common.vpc_security_group_ids
  iam_instance_profile   = local.instance_common.iam_instance_profile
  key_name               = local.instance_common.key_name

  user_data = templatefile("${path.module}/templates/agent.sh.tftpl", {
    k3s_version = var.k3s_version
    k3s_token   = random_password.k3s_token.result
    server_ip   = aws_instance.server.private_ip
    region      = var.region
  })

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = { Name = "${var.cluster_name}-agent-${count.index + 1}", Role = "agent" }

  lifecycle {
    ignore_changes = [ami]
  }
}
