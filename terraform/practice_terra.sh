# Practice Terraform commands
terraform init
terraform plan -out=tfplan
terraform show tfplan          # review before apply
terraform apply tfplan
terraform state list           # see managed resources
terraform state show aws_db_instance.primary

# Check for drift
terraform plan                 # any changes = configuration drift
