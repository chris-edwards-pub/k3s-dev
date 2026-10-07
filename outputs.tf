output "admin_cidr" {
  description = "CIDR allowed full network access to the nodes"
  value       = local.admin_cidr
}

output "server_public_ip" {
  description = "Elastic IP of the k3s server (API endpoint)"
  value       = aws_eip.server.public_ip
}

output "nodes" {
  description = "All nodes with IDs and IPs"
  value = merge(
    {
      (aws_instance.server.tags.Name) = {
        id         = aws_instance.server.id
        public_ip  = aws_eip.server.public_ip
        private_ip = aws_instance.server.private_ip
      }
    },
    {
      for a in aws_instance.agent : a.tags.Name => {
        id         = a.id
        public_ip  = a.public_ip
        private_ip = a.private_ip
      }
    }
  )
}

output "ssh_commands" {
  value = concat(
    ["ssh ec2-user@${aws_eip.server.public_ip}"],
    [for a in aws_instance.agent : "ssh ec2-user@${a.public_ip}"]
  )
}

output "ssm_commands" {
  value = concat(
    ["aws ssm start-session --region ${var.region} --target ${aws_instance.server.id}"],
    [for a in aws_instance.agent : "aws ssm start-session --region ${var.region} --target ${a.id}"]
  )
}

output "kubeconfig_command" {
  description = "Fetch the kubeconfig (available ~2-3 min after apply)"
  value       = "aws ssm get-parameter --region ${var.region} --name /${var.cluster_name}/kubeconfig --with-decryption --query Parameter.Value --output text > kubeconfig && chmod 600 kubeconfig"
}

output "cluster_name" {
  value = var.cluster_name
}

output "region" {
  value = var.region
}

output "server_instance_id" {
  value = aws_instance.server.id
}

output "auto_stop" {
  description = "Nightly auto-stop schedule (null when disabled)"
  value = var.auto_stop_enabled ? {
    function       = aws_lambda_function.auto_stop[0].function_name
    schedule       = var.auto_stop_schedule
    timezone       = var.auto_stop_timezone
    invoke_command = "aws lambda invoke --region ${var.region} --function-name ${aws_lambda_function.auto_stop[0].function_name} /dev/stdout"
  } : null
}
