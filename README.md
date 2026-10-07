# k3s-dev

A small, low-cost 3-node [k3s](https://k3s.io) cluster on AWS for development, managed with Terraform.

## Architecture

| Item | Value |
| --- | --- |
| Region | `us-east-1` |
| Nodes | 1 server (control plane + workloads) + 2 agents |
| Instance type | `t3.small` (Intel, 2 vCPU / 2 GiB), **Spot**, persistent, stop on interruption |
| OS | AlmaLinux 9 (x86_64), SELinux enforcing with `k3s-selinux`. Official AMI, owner `764336703387` |
| Disk | 20 GiB gp3, encrypted |
| k3s | `v1.36.5+k3s1` (Traefik, CoreDNS, local-path, metrics-server enabled) |
| Network | Dedicated VPC `10.20.0.0/16`, one public subnet, no NAT gateway |
| Server endpoint | Elastic IP (stable across stop/start) |
| State | `s3://<state_bucket>/k3s-dev/terraform.tfstate` (shared state bucket, S3-native locking). See [Terraform state](#terraform-state) |

**Access:** one security group allows **all traffic from `admin_cidr`**. By default this is your current public IP (`/32`), looked up when you run plan or apply. Nodes can reach each other on any port. Nothing else on the internet can reach the nodes. Shell access is SSH as `ec2-user` (key from `~/.ssh/id_ed25519.pub`) or SSM Session Manager.

**Estimated cost:** about $33/month while running, based on 7-day Spot prices in October 2026.

- Spot instances: about $17.50 (3 × $0.008/hr in us-east-1a)
- Public IPv4 addresses: about $11
- EBS: about $4.80
- Auto-stop Lambda, scheduler, SSM and S3 state: under $0.01

Run `./cluster.sh down` to stop the nodes (about $8.45/mo while stopped), or `./cluster.sh destroy` to bring the cost to $0. As a safety net, the nodes are also [stopped automatically every night at 3 AM](#auto-stop).

## Prerequisites

- Terraform >= 1.10
- AWS CLI v2 with credentials for the target account
- kubectl
- python3 and ssh (both included with macOS)
- An SSH public key at `~/.ssh/id_ed25519.pub`, or set `ssh_public_key_path`

`./cluster.sh` checks for these tools and lists any that are missing.

## Fresh clone

```sh
git clone <repo-url> k3s-dev && cd k3s-dev
scripts/bootstrap-state-bucket.sh              # once per AWS account; prints the bucket name
cp terraform.tfvars.example terraform.tfvars   # set state_bucket (required) and any overrides
./cluster.sh up                                # runs terraform init with your bucket, then builds
```

**Private settings stay in `terraform.tfvars`,** which is gitignored. That covers the state bucket name (it includes your AWS account ID), your time zone, and any overrides. Nothing account-specific is committed. Terraform's `backend` block can't read variables, so `cluster.sh` reads `state_bucket` and `state_region` from `terraform.tfvars` and passes them to `terraform init -backend-config=...`. It re-runs init automatically when needed. To run Terraform by hand:

```sh
terraform init -backend-config="bucket=<state_bucket>" -backend-config="region=<state_region>"
```

## Usage

Day-to-day work goes through `./cluster.sh`. It needs `python3`, which macOS includes.

```sh
./cluster.sh up        # create or start the cluster, fetch ./kubeconfig, wait for nodes Ready
./cluster.sh down      # stop all 3 nodes (cheap pause)
./cluster.sh status    # instance states, IPs, nodes
./cluster.sh refresh   # rebuild kubeconfig from the live server, update SSM + local file
./cluster.sh kubeconfig  # just fetch the kubeconfig from SSM
./cluster.sh destroy   # terraform destroy + delete kubeconfig (local + SSM)

export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

`up` and `destroy` pass any extra arguments to Terraform, for example `./cluster.sh up -auto-approve`.

| Command | What it does | Cost afterwards |
| --- | --- | --- |
| `up` | Starts stopped nodes, then runs `terraform apply`. The apply creates the cluster if it doesn't exist, refreshes agent IPs, and updates the admin-IP rule. Then it waits for the kubeconfig in SSM and for all nodes to be Ready. | about $30/mo |
| `down` | Runs `aws ec2 stop-instances` on all nodes. Data, the Elastic IP, and the kubeconfig are kept. | about $9/mo (EBS plus the idle Elastic IP) |
| `destroy` | Runs `terraform destroy`, then deletes the SSM parameter and `./kubeconfig`. | $0 |
| `refresh` | Copies `/etc/rancher/k3s/k3s.yaml` from the server over SSH, rewrites the address to the Elastic IP, and saves it to SSM and `./kubeconfig`. Use it after k3s rotates its certificates (about once a year). | |

Notes on `up` and `down`:
- After `down`, AWS needs about 3 minutes to finish stopping the persistent Spot requests. Running `up` before then waits automatically.
- Agents get new public IPs on start. Run `./cluster.sh status` or `terraform output ssh_commands` to see them. The server keeps its Elastic IP, so the kubeconfig stays valid.
- `up` only fetches the kubeconfig once the copy in SSM is newer than the current server instance. It compares against the network interface's attach time, which doesn't change on stop and start, so it never picks up a stale copy from a destroyed cluster.

Manual equivalents:

```sh
terraform apply
aws ssm get-parameter --name /k3s-dev/kubeconfig --with-decryption \
  --query Parameter.Value --output text > kubeconfig && chmod 600 kubeconfig
ssh ec2-user@$(terraform output -raw server_public_ip)
aws ssm start-session --target <instance-id>
```

## Configuration

To override defaults, copy `terraform.tfvars.example` to `terraform.tfvars`. Variables are defined in `variables.tf`:

| Variable | Default | Notes |
| --- | --- | --- |
| `instance_type` | `t3.small` | Use Intel types only (t3/m6i/…), not t3a/AMD or Graviton |
| `use_spot` | `true` | Set to `false` for on-demand |
| `agent_count` | `2` | |
| `root_volume_gb` | `20` | |
| `k3s_version` | `v1.36.5+k3s1` | |
| `admin_cidr` | `null` | `null` means your current IP as a `/32` |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | |
| `vpc_cidr` | `10.20.0.0/16` | |
| `auto_stop_enabled` | `true` | Nightly auto-stop on or off |
| `auto_stop_schedule` | `cron(0 3 * * ? *)` | EventBridge Scheduler expression |
| `auto_stop_timezone` | `UTC` | IANA time zone, for example `America/New_York`; daylight saving time is handled |
| `state_bucket` | (required) | S3 bucket for Terraform state. Used by `cluster.sh` for `terraform init` |
| `state_region` | `us-east-1` | Region of `state_bucket` |

## Files

| File | Purpose |
| --- | --- |
| `backend.tf` | Partial S3 backend (key `k3s-dev/terraform.tfstate`). The bucket comes from `terraform.tfvars` at init time |
| `terraform.tfvars.example` | Template for your private, gitignored `terraform.tfvars` |
| `versions.tf` | Terraform/provider versions, AWS provider, and default tags |
| `variables.tf` | Inputs |
| `network.tf` | VPC, subnet, IGW, and routes. The AZ is chosen from those that offer the instance type |
| `security.tf` | Admin IP lookup and the node security group |
| `keypair.tf` | SSH key pair |
| `iam.tf` | Node role: SSM core access, plus `ssm:PutParameter` on `/k3s-dev/*` |
| `main.tf` | k3s token, AMI, Elastic IP, server and agent instances |
| `templates/server.sh.tftpl` | Server user-data. Prepares the OS (SSM agent, container-selinux, disables firewalld and nm-cloud-setup), installs k3s and AWS CLI v2, and publishes the kubeconfig to SSM |
| `templates/agent.sh.tftpl` | Agent user-data. Same OS prep as the server, then waits for the server and joins it |
| `outputs.tf` | IPs, instance IDs, helper commands, and the `cluster_name`, `region` and `server_instance_id` values that `cluster.sh` uses |
| `cluster.sh` | Lifecycle script: up, down, destroy, refresh, kubeconfig and status |
| `scripts/bootstrap-state-bucket.sh` | Creates and hardens the shared Terraform state bucket; safe to rerun |
| `.gitignore`, `.gitattributes` | Keep state, kubeconfig, tfvars, build output and local settings out of git; force LF line endings |
| `autostop.tf` | Nightly auto-stop: Lambda, EventBridge Scheduler schedule, IAM roles and log group |
| `lambda/auto_stop.py` | Lambda handler that stops running instances tagged `Project=k3s-dev` |

## Auto-stop

In case you forget `./cluster.sh down`, an **EventBridge Scheduler** schedule runs a Lambda (`k3s-dev-auto-stop`) at **03:00 every day in `auto_stop_timezone`** (default UTC; set your own in `terraform.tfvars`). The Lambda stops every running instance tagged `Project=k3s-dev`. That has the same effect as `./cluster.sh down`: data, the Elastic IP and the kubeconfig are kept, and `./cluster.sh up` brings the cluster back.

- **Tag-based:** the Lambda finds instances by tag, so it keeps working after a rebuild changes the instance IDs. If nothing is running, it logs "nothing running" and exits.
- **Least privilege:** the Lambda can stop **only** instances tagged `Project=k3s-dev`. `DescribeInstances` is allowed account-wide because AWS can't restrict it to specific resources. The scheduler can invoke only this one function.
- **Cost:** about $0, since it runs 30 times a month and stays inside the free tiers.
- **Logs:** `aws logs tail /aws/lambda/k3s-dev-auto-stop --since 1d`, kept for 14 days.
- **Run it now:** `aws lambda invoke --function-name k3s-dev-auto-stop /dev/stdout`
- **Check it:** `./cluster.sh status` prints the schedule, or run `aws scheduler get-schedule --name k3s-dev-auto-stop`.
- **Change or disable it:** set `auto_stop_schedule`, `auto_stop_timezone` or `auto_stop_enabled = false` in `terraform.tfvars`, then run `./cluster.sh up`. For example, `cron(0 19 ? * MON-FRI *)` stops the nodes at 7 PM on weekdays.
- **Created and removed with the cluster:** `./cluster.sh up` creates it and `./cluster.sh destroy` removes it.

## Terraform state

State is stored in a dedicated bucket shared by multiple Terraform projects. Each project uses its own prefix:

```
s3://<state_bucket>/                ← e.g. tfstate-<account-id>-us-east-1
  k3s-dev/terraform.tfstate          ← this project
  <other-project>/terraform.tfstate  ← add more projects this way
```

**Bucket settings,** all applied by `scripts/bootstrap-state-bucket.sh [bucket] [region]`:
- versioning
- SSE-S3 encryption
- Block Public Access, with ACLs disabled
- a bucket policy that denies non-TLS access
- lifecycle rules: noncurrent versions expire after 90 days, expired delete markers are removed, and incomplete uploads are aborted after 7 days

The script is safe to rerun. With no arguments, it uses `tfstate-<account-id>-us-east-1`.

**Using it from another project:**
```hcl
terraform {
  backend "s3" {
    bucket       = "<state_bucket>"
    key          = "<project>/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

**Moving an existing project in.** Change that project's `backend` block as shown above, then run `terraform init -migrate-state` from that project.

## Operations notes

- **If your IP changes,** run `terraform apply` to update the access rule.
- **Spot interruption:** a reclaimed node *stops* and restarts once capacity returns. Agents rejoin over the server's private IP, which doesn't change. Agent public IPs do change; the server's Elastic IP doesn't.
- **Bootstrap logs** are on each node at `/var/log/k3s-bootstrap.log`. User-data runs only on first boot. Service logs are in `journalctl -u k3s` (server) and `journalctl -u k3s-agent` (agents).
- **The k3s token** is in Terraform state and in instance user-data. That's acceptable for dev, but don't reuse this setup for production.
- **Changing `user_data`** (for example, `k3s_version`) doesn't rebuild running nodes. To rebuild, run `terraform apply -replace=aws_instance.server` (or replace the agents).
- **The AMI is pinned at creation** (`ignore_changes = [ami]`), so new AlmaLinux 9 point releases don't replace nodes. Patch running nodes with `sudo dnf update`, or rebuild with `-replace`.
- **Why AlmaLinux 9 and not 10:** Rancher doesn't publish `k3s-selinux` for EL10 yet (`rpm.rancher.io/.../centos/10` returns 404). Check again before moving to 10.
- **SELinux is enforcing.** If a workload fails with permission errors on host paths, check for denials with `sudo ausearch -m avc -ts recent`.
- **The Elastic IP changes** after a full `destroy` and `apply`, so fetch the kubeconfig from SSM again and clear old host keys with `ssh-keygen -R <ip>`.
- **After `terraform destroy`,** check the EC2 console and confirm no persistent Spot requests are left.

## Changelog

- Initial build: 1 server + 2 agents on t3.small Spot, k3s v1.36.5, an isolated VPC with no NAT, and full access from the admin IP only.
- Switched the node OS from Ubuntu 24.04 to AlmaLinux 9, with SELinux enforcing via `k3s-selinux`. EL10 isn't supported yet.
- Added `cluster.sh` (up/down/destroy/refresh/kubeconfig/status). `down` stops the nodes and keeps all data.
- Added the nightly auto-stop: a Lambda run by EventBridge Scheduler, limited to `Project=k3s-dev` instances.
- Moved state to a dedicated shared bucket created by `scripts/bootstrap-state-bucket.sh`.
- Prepared the repo for public release: private values (the state bucket and time zone) moved to the gitignored `terraform.tfvars`, the backend became a partial config filled in by `cluster.sh`, and the auto-stop time zone now defaults to UTC.
