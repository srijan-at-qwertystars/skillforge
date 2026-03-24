output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Map of availability zone to public subnet ID"
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "private_subnet_ids" {
  description = "Map of availability zone to private subnet ID"
  value       = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "nat_gateway_ips" {
  description = "List of Elastic IPs assigned to NAT Gateways"
  value       = [for eip in aws_eip.nat : eip.public_ip]
}

output "default_security_group_id" {
  description = "ID of the restrictive default security group"
  value       = aws_default_security_group.this.id
}

output "flow_log_group_name" {
  description = "CloudWatch Log Group name for VPC Flow Logs (empty if disabled)"
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : ""
}
