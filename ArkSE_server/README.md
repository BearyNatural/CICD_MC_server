# ArkSE Server

Containerised ARK: Survival Evolved dedicated server infrastructure for AWS ECS Fargate.

## Required Secrets

Add these GitHub Actions secrets before creating the stack:

| Secret Name | Required | Notes |
|-------------|----------|-------|
| `AWS_ACCOUNT_ID` | yes | Existing OIDC workflow secret |
| `DISCORD_WEBHOOK_URL` | yes | Stored in AWS Lambda env so Discord messages come from AWS |
| `ARK_ADMIN_PASSWORD` | yes | ARK admin password |
| `ARK_SERVER_PASSWORD` | no | Optional join password |

## Workflow

Use **Actions -> ArkSE Stack Control**.

Create:

```yaml
action: create
stack_name: my-ark-server
stack_config_profile: default
template_path: ArkSE_server/CFN_ArkSEServer.yaml
server_state_on_create: Stopped
```

Start:

```yaml
action: start
stack_name: my-ark-server
```

Stop:

```yaml
action: stop
stack_name: my-ark-server
```

Delete:

```yaml
action: delete
stack_name: my-ark-server
```

## Runtime Behavior

- The ARK server runs as `renegademaster/ark-se-dedicated-server:latest`.
- ARK data is persisted on EFS. No S3 backup bucket or backup URL is created.
- UDP ports `7777`, `7778`, and `27015` are exposed through a Network Load Balancer.
- `arkserver.bearynatural.dev` should point at the stack output `ArkLoadBalancerDNS`.
- A CloudWatch alarm watches for new NLB flows and asks Lambda to start the stack when traffic hits the endpoint.
- Idle shutdown checks the ARK query port every 5 minutes and stops the stack after 20 minutes with zero players.
- Start, stop, delete-request, task-error, and CloudFormation failure notifications are sent by AWS Lambda to Discord.
- The workflow maintains a small persistent `arkse-discord-notifier` CloudFormation stack so ARK stack errors can be reported even if the game server stack fails early during create/update/delete.

The wake trigger is based on UDP/game-query traffic reaching the load balancer. A literal ICMP `ping arkserver.bearynatural.dev` will not wake the server because NLB listeners do not receive ICMP traffic.

## Profiles

Non-secret defaults live in `ArkSE_server/arkse-stack-config.json`.

- `default` uses `arkserver.bearynatural.dev`
- `dev` uses `arkserver-dev.bearynatural.dev`

Keep passwords and webhooks in GitHub Secrets, not in the config file.
