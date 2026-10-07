# Partial backend config: the bucket and its region are private, so they live in
# terraform.tfvars (state_bucket / state_region) and are passed in at init time:
#   ./cluster.sh <any command>   (runs init for you), or manually:
#   terraform init -backend-config="bucket=<state_bucket>" -backend-config="region=<state_region>"
terraform {
  backend "s3" {
    key          = "k3s-dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
