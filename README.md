# CICD Minecraft Server - WIP

Automated CloudFormation stack management for Minecraft servers on AWS ECS Fargate, controlled via GitHub Actions with Discord notifications.

## Features

- **Create/Start/Stop/Delete** CloudFormation stacks via workflow dispatch
- **Automatic world backups** to S3 before server shutdown
- **Idle auto-shutdown** after 20 minutes with no players online
- **Discord notifications** for all stack operations with login details & backup links
- **OIDC authentication** - no long-lived AWS credentials stored in GitHub

## Quick Start

### Prerequisites

- An AWS account (new or existing)
- GitHub repository access with Actions enabled
- Discord webhook URL for notifications

### 1. Configure GitHub Repository Secrets (Do this first)

Before running any workflow/scripts, go to **Settings** -> **Secrets and variables** -> **Actions** and add:

| Secret Name | Value | Notes |
|-------------|-------|-------|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID | Found in AWS Console top-right |
| `DISCORD_WEBHOOK_URL` | Your Discord webhook URL | [Create webhook](https://discord.com/developers/applications) ||

### 2. Configure DNS record (No Route 53 required)

1. Sign in to domain registrar and create/choose a subdomain (for example `mc-yourname.mooo.com`).
2. In the DNS dashboard, open that record and copy the **Direct URL** / update URL.


### 3. Set Up OIDC + IAM in AWS (CloudFormation only)

Deploy the `oidc-iam-setup.yaml` template:

```bash
aws cloudformation create-stack \
  --stack-name github-oidc-setup \
  --template-body file://oidc-iam-setup.yaml \
  --parameters ParameterKey=GitHubOrg,ParameterValue=YOUR_GITHUB_ORG \
                ParameterKey=GitHubRepo,ParameterValue=CICD_MC_server \
  --capabilities CAPABILITY_NAMED_IAM
```

The OIDC role is configured with a 12-hour maximum session duration so S3 backup links can last as long as possible without long-lived AWS access keys. If the stack already exists, update it with the current `oidc-iam-setup.yaml` before relying on backup links.

Then attach permissions policy to the role:

```bash
aws iam put-role-policy \
  --role-name GitHubActionsOIDCRole \
  --policy-name GitHubActionsMinecraftPolicy \
  --policy-document file://github-actions-policy.json
```

### 4. Deploy Your First Stack

1. Go to **Actions** tab in your GitHub repo
2. Select **Minecraft Stack Control** workflow
3. Click **Run workflow**
4. Fill in:
   - **action:** `create`
   - **stack_name:** `my-minecraft-server`
    - **stack_config_profile:** `default`
   - **template_path:** `Minecraft_server/CFN_FargateServer.yaml`
    - **dns_hostname:** `mc-yourname.mooo.com`
    - **vpc_id:** optional (leave blank to auto-discover default VPC)
    - **subnet_id:** optional (leave blank to auto-discover subnet)
   - **server_state_on_create:** `Running`
5. Click **Run workflow**
6. Monitor progress in the workflow logs
7. Discord notification will arrive with server IP & login details

## Workflow Actions

### Create Stack

Creates a new CloudFormation stack for a Minecraft server.

```
action: create
stack_name: my-server
stack_config_profile: default
template_path: Minecraft_server/CFN_FargateServer.yaml
dns_hostname: mc-yourname.mooo.com
vpc_id:
subnet_id:
seed:
server_state_on_create: Running
```

### Start Stack

Starts an existing stopped stack (scales ECS service to 1).

```
action: start
stack_name: my-server
stack_config_profile: default
dns_hostname: mc-yourname.mooo.com
```

## Stack Config Profiles

The workflow can load non-secret defaults from `Minecraft_server/stack-config.json` using `stack_config_profile`.

- Inputs override profile values.
- Profile values override empty inputs.
- Keep secrets in GitHub Secrets (for example `FREEDNS_UPDATE_URL`).
- `include_backup_link: true` includes a pre-signed backup URL in stop notifications; `false` disables the URL.

Example `Minecraft_server/stack-config.json`:

```json
{
    "default": {
        "template_path": "Minecraft_server/CFN_FargateServer.yaml",
        "dns_hostname": "your-server.example.com",
        "vpc_id": "",
        "subnet_id": "",
        "minecraft_image_tag": "latest",
        "memory": "2048",
        "cpu": "1024",
        "seed": "5685761492797",
        "whitelist": [
            "kaylene",
            "BenBenGold"
        ],
        "admin_player_names": [
            "kaylene"
        ],
        "log_group_name": "/ecs/minecraft5",
        "include_backup_link": true
    }
}
```

### Stop Stack

Stops the server and runs backup task before shutdown.

```
action: stop
stack_name: my-server
include_backup_link: true
```

### Idle Auto-Shutdown

The Minecraft container is configured to stop itself after 20 minutes with no players online. An EventBridge rule then invokes a Lambda function that sets the ECS service desired count to `0`, then updates the CloudFormation stack parameter to `ServerState=Stopped` so future stack updates stay aligned.

This idle shutdown does not run the backup task. Use the manual `stop` workflow action when you want a backup before shutdown.

### Delete Stack

Permanently deletes the stack and all resources.

```
action: delete
stack_name: my-server
```

## CloudFormation Templates

### Minecraft_server/CFN_FargateServer.yaml

Creates:
- ECS Cluster & Fargate Service
- EFS file system for persistent world data
- S3 bucket for backups
- CloudWatch log group
- Security groups for Minecraft traffic (port 25565)
- Optional FreeDNS metadata parameters for stable hostname reporting

**Parameters:**
- Non-sensitive server settings are managed in `Minecraft_server/stack-config.json` and passed on `create`.
- Typical profile keys are `memory`, `cpu`, `seed`, `whitelist`, `admin_player_names`, `minecraft_image_tag`, `log_group_name`, `dns_hostname`, and `include_backup_link`.
- `ServerState` is controlled by workflow action (`create` initial state, then `start` and `stop`).
- Keep sensitive values out of `Minecraft_server/stack-config.json`. Use GitHub Secrets for `FREEDNS_UPDATE_URL`.

Workflow note:
- `vpc_id` and `subnet_id` are optional workflow inputs for `create`.
- If omitted, the workflow auto-discovers default VPC and a subnet.

## Backup & Restore

### Automatic Backups

When you **stop** the server, GitHub Actions:
1. Runs a backup ECS task
2. Zips `/data/world` directory
3. Uploads to S3: `s3://{stack-name}-{seed}/world_YYYYMMDDhhmmss.zip`
4. Generates an S3 pre-signed download URL valid for up to 12 hours
5. Posts download link in Discord

S3 pre-signed URLs created with GitHub OIDC credentials cannot outlive the temporary AWS role session that created them. The workflow requests the AWS maximum role session of 12 hours before generating the Discord backup link.

### Manual Restore

To restore a backup:

1. Download the backup file from S3 or Discord link
2. Stop the stack via GitHub Actions
3. Extract backup to EFS:
   ```bash
   # SSH into ECS task or use Systems Manager Session Manager
   unzip world_backup.zip -d /data/
   ```
4. Start the stack

## Troubleshooting

### Workflow fails with "No running ECS task found"

- Give the task ~2 minutes to launch after stack creation
- Check CloudWatch logs: `/ecs/minecraft5` (or your log group)
- Verify ECS cluster has capacity & subnets are correct

### Backup task fails

- Check task execution role has S3 permissions
- Verify EFS mount is accessible from backup container
- Check backup task definition `MinecraftBackupTask` exists in CloudFormation

### OIDC authentication fails

- Verify `token.actions.githubusercontent.com` is listed under IAM -> Identity Providers
- Check role trust policy includes correct GitHub org/repo
- Ensure `AWS_ACCOUNT_ID` secret matches actual AWS account

### Discord notification doesn't arrive

- Verify `DISCORD_WEBHOOK_URL` secret is set in GitHub
- Check workflow logs for curl errors
- Ensure Discord webhook URL is still valid (webhooks can expire)

## Architecture

```
GitHub Actions
    ->
OIDC Token
    ->
AWS STS AssumeRole (GitHubActionsOIDCRole)
    ->
CloudFormation API
    ->
ECS Fargate + EFS + S3
    ->
Discord Webhook
```

## Cost Optimization

- **ECS Fargate**: ~$0.05/hour (t3.medium equivalent, 2GB RAM)
- **EFS**: ~$0.30/GB-month (typical world ~2GB = $0.60/month)
- **S3**: ~$0.023/GB-month (backups)
- **Stop when not playing** via GitHub Actions to avoid charges

**Monthly estimate (server running 8 hours/day):**
- ECS: ~$12 (240 hours x $0.05)
- EFS: ~$0.60
- S3: ~$0.05
- **Total: ~$12.65/month**

## File Structure

```
CICD_MC_server/
├── README.md                          # This file
├── oidc-iam-setup.yaml               # CloudFormation for OIDC + IAM
├── github-actions-policy.json        # IAM permissions policy
├── Minecraft_server/
│   ├── stack-config.json             # Non-secret profile defaults for workflow
│   └── CFN_FargateServer.yaml        # Minecraft stack template
├── .github/workflows/
│   └── minecraft-stack-control.yml   # GitHub Actions workflow
└── .gitignore
```

## Security Notes

- No AWS credentials stored in repo (OIDC only)
- No secrets hardcoded (use GitHub Secrets)
- IAM role has least-privilege permissions
- Keep repository private to avoid exposing infrastructure details
- Rotate Discord webhook if accidentally exposed

## License

MIT

---

**Questions?** Check the workflow logs in GitHub Actions for detailed error messages.
