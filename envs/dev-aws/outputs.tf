# Outputs, alphabetical.

output "public_url" {
  description = "URL of the nginx web server."
  value       = "http://${aws_instance.web.public_ip}"
}

output "security_group_id" {
  description = "Security group to alter by hand for the part D drift exercise."
  value       = aws_security_group.web.id
}

output "ssh_command" {
  description = "Connection command, valid from the admin address only."
  value       = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ubuntu@${aws_instance.web.public_ip}"
}
