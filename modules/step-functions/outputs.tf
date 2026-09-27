output "state_machine_arn" {
  description = "ARN of the booking saga state machine. API Gateway's integration (Arrow 6) starts an execution of this state machine."
  value       = aws_sfn_state_machine.booking_saga.arn
}

output "state_machine_name" {
  value = aws_sfn_state_machine.booking_saga.name
}
