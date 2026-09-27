# These ARNs/names are consumed by: the step-functions module (which
# invokes search/lock_slot/process_payment/release_lock as state machine
# tasks), and the ROOT module (which wires the SQS event_source_mapping
# to notify, and the EventBridge target to release_lock -- see the root
# README for why those two specific wirings live at the root level
# instead of inside a module).

output "search_function_arn" {
  value = aws_lambda_function.search.arn
}

output "lock_slot_function_arn" {
  value = aws_lambda_function.lock_slot.arn
}

output "process_payment_function_arn" {
  value = aws_lambda_function.process_payment.arn
}

output "release_lock_function_arn" {
  value = aws_lambda_function.release_lock.arn
}

output "release_lock_function_name" {
  value = aws_lambda_function.release_lock.function_name
}

output "notify_function_arn" {
  value = aws_lambda_function.notify.arn
}

output "notify_function_name" {
  value = aws_lambda_function.notify.function_name
}
