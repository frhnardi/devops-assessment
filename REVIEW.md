# Review

I spent about two hours on this. Below is what I'd have written on the PR, then what
I actually changed, then what I deliberately left alone.

Short version: the service works, but a container escape or a single leaked image
would have handed over the whole AWS account. That's where I spent my time.

## Blockers

### 1. The database password ships in four places

`.env` was in the repo with a real-looking password and a GitHub token, and
`.gitignore` only covered `__pycache__` and `*.pyc`. The same password was also
hardcoded as a fallback in `app.py`, as a Terraform variable default, and baked into
the image with `ENV DB_PASSWORD=` in the Dockerfile.

The Dockerfile one is the worst of them. `ENV` writes the value into the image layer,
so anyone who can pull from ECR gets the password back with a single `docker history`.
There was also no `.dockerignore`, so `COPY . .` copied `.env` into the image too.

Fixed. The value is gone from all four places. Terraform now creates a Secrets Manager
secret and the task definition pulls it through `secrets`/`valueFrom` instead of
`environment`, because anything in `environment` shows up in plain text in the ECS
console and in `describe-task-definition`. Terraform creates the secret container only,
not the version, so the password never enters the state file. Whoever owns the password
writes it once with the CLI.

Worth saying out loud: rotate that password. Once a credential has been in a repo you
treat it as burned, whether or not you think anyone saw it.

### 2. The task role had AdministratorAccess

One role was doing double duty as both `task_role_arn` and `execution_role_arn`, and it
had `AdministratorAccess` attached. Those two roles exist for different reasons. The
execution role is what the ECS agent uses to pull the image and write logs. The task
role is what your code uses at runtime.

Collapsing them into one admin role means any RCE in the container is a full account
compromise. Given the app was also running the Werkzeug debugger (see below), that path
was not theoretical.

Fixed. There are now two roles. The execution role gets the AWS-managed
`AmazonECSTaskExecutionRolePolicy` plus `secretsmanager:GetSecretValue` scoped to the one
secret ARN. The task role has no policies at all, because this app never calls an AWS API.

### 3. One security group, wide open, shared by the ALB and the tasks

The group allowed TCP 0-65535 from 0.0.0.0/0 and had a separate rule opening port 22 to
the internet. Port 22 on Fargate does nothing, which is a decent sign nobody read this
block before merging it.

The bigger problem is that the same group was attached to the ALB and to the ECS service,
and the tasks have public IPs. So the tasks were directly reachable from the internet on
8080 and the load balancer was decoration. Any WAF rule, access log, or TLS termination
you put on the ALB gets bypassed by connecting to the task.

Fixed. Two groups now. The ALB group takes 80 from anywhere. The task group takes 8080
from the ALB's security group ID and nothing else.

### 4. The container ran the Flask development server with debug on

`app.py` ends with `app.run(host="0.0.0.0", port=8080, debug=True)` and the Dockerfile's
`CMD` ran that file directly, so debug mode was live in production. The Werkzeug debugger
exposes an interactive Python console on unhandled exceptions. That's remote code
execution, and it chains directly into the admin role above. It's also single threaded,
so one slow request blocks the whole task.

Fixed by switching `CMD` to gunicorn. I want to flag the reasoning here because it looks
like I skipped something: I left `debug=True` in `app.py` alone. Under gunicorn the
`if __name__ == "__main__"` block never executes, so the debugger can't turn on. That line
is the local development entrypoint, and debug mode is the right default there. The bug
was never "debug=True exists", it was "the container runs the dev server". I fixed that
one and left the developer convenience intact.

### 5. The test step could not pass, and the pipeline was built to not care

`continue-on-error: true` on the test step meant a red test still shipped to production.
That's bad enough on its own. But when I actually ran the suite, it turned out the tests
had never run at all:

```
ModuleNotFoundError: No module named 'app.app'; 'app' is not a package
no tests collected, 1 error in 0.19s
```

`app/` had no `__init__.py`, so `from app.app import app` could never resolve. The green
checkmark on every build was `continue-on-error` swallowing a collection error. Nobody
noticed because the build was always green, which is exactly what that flag buys you.

Fixed. Added `app/__init__.py`, dropped `continue-on-error`, and moved the tests into
their own job that `deploy` depends on. `pytest app/` now reports `2 passed`.

### 6. Terraform ran from CI with no remote state

There's no `backend` block, but the workflow ran `terraform init && terraform apply
-auto-approve` on a GitHub runner. Runners are ephemeral, so the state file is gone the
moment the job ends. Every push to main would try to create the whole stack from scratch
and fail on duplicate names. There was no locking either, so two merges landing close
together could tear the state apart.

I did not fix this one, on purpose. See the last section for why.

## Should fix

**`FROM python:latest` and a cache-hostile layer order.** An unpinned tag means today's
build and next month's build are different software, which makes "it worked yesterday"
unanswerable. `COPY . .` before `pip install` also meant every one-line source change
reinvalidated the dependency install. Moved to `python:3.12-slim`, copy
`requirements.txt` first, install with `--no-cache-dir`, then copy source. Image went from
1.64GB to 200MB.

**The container ran as root.** Added a non-root `appuser`. Verified with `docker exec`.

**`flask` was unpinned.** Same reproducibility problem as the base image, with a supply
chain angle on top. Pinned to `flask==3.1.0` and `gunicorn==23.0.0`.

**No logs anywhere.** The container definition had no `logConfiguration`, so the service
was emitting nothing to CloudWatch. This is why the "how would you know it's down"
question had no answer. Added an awslogs config and a log group with 30 day retention,
because a log group with no retention bills forever.

**Health check pointed at the wrong endpoint.** The target group had no `health_check`
block, so it defaulted to `/` on the traffic port. There's a purpose-built `/health`
endpoint sitting right there. It happened to work because `/` returns 200, but that's
luck, not design. Pointed it at `/health`.

**A bad deploy had no way to stop itself.** No `deployment_circuit_breaker`, so a broken
image would crash loop indefinitely while ECS kept trying. Enabled it with `rollback = true`.

**`desired_count = 1` across two AZs.** One task means no redundancy and a gap on every
deploy. Raised to 2 and added `health_check_grace_period_seconds` so a slow first start
doesn't get killed before it's ready.

**Everything tagged `latest`.** Two separate problems. The task definition never changes
when the image changes, so Terraform reports no diff even though the code is different.
And there is no earlier artifact to point at, so rollback has no target. The pipeline now
tags with the commit SHA, `image_tag` has no default, and ECR is set to `IMMUTABLE` so a
tag can't be quietly overwritten.

**Static AWS keys in CI.** Long-lived `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in
repo secrets. Replaced with OIDC role assumption, so the runner gets short-lived
credentials and there's nothing standing to leak.

**`docker push` would have failed anyway.** There was no `aws ecr get-login-password`
step, so the push step was broken, not just unsafe. Added the ECR login action. Worth
noting for its own sake: this pipeline had never run successfully end to end.

**No concurrency control or permissions block.** Added `concurrency: deploy-main` so two
applies can't race, and narrowed `permissions` to what the job needs.

**Redundant `force-new-deployment`.** Once the image tag is the commit SHA, the task
definition changes on every deploy and ECS rolls automatically. The extra
`update-service` call was papering over the `latest` problem and causing drift from what
Terraform thought was deployed. Removed.

**Hardcoded AZ suffixes.** `"${var.aws_region}a"` breaks in regions where that AZ isn't
available to the account. Switched to the `aws_availability_zones` data source.

## Nice to have

- No tags on any resource. Added `default_tags` on the provider, which is one block and
  makes cost allocation possible.
- No `outputs.tf`, so the ALB DNS name had to be dug out of the console. Added.
- No ECR lifecycle policy, so images accumulate and bill forever.
- `aws_ecs_service` needed `depends_on` on the listener. Without it the first apply can
  hit the classic "target group does not have an associated load balancer" race.
- No ALB access logs, no VPC flow logs, no deletion protection.
- Actions pinned to tags rather than commit SHAs.
- `/health` returns 200 unconditionally. Fine for a stateless service, but it can't
  distinguish "process is up" from "process can do its job". If this service ever gains a
  real dependency, that distinction starts to matter.

## One thing the assessment asks for that deserves a caveat

The README asks for `terraform fmt -check` and `terraform validate` output as evidence.
I ran both on the untouched starter before changing anything, and both passed:

```
$ terraform fmt -check    # exit 0
$ terraform validate
Success! The configuration is valid.
```

That's a configuration with `AdministratorAccess` and a security group open to the world
on every TCP port. `validate` checks syntax and provider schema. It has no opinion about
whether what you wrote is a good idea. Passing it is a floor, not evidence of a review.
Catching this class of problem needs `tfsec` or `checkov`, so I added a tfsec step to the
pipeline.

## Show your work

Terraform, run from `infra/` after the changes:

```
$ terraform fmt -check
(exit 0, no output)

$ terraform validate
Success! The configuration is valid.
```

I also ran a real plan, since it needs no resources to be created:

```
$ terraform plan -var="image_tag=abc1234"
Plan: 22 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + alb_dns_name       = (known after apply)
  + ecr_repository_url = (known after apply)
```

Image size:

```
$ docker images demo-api
TAG      SIZE
before   1.64GB
after    200MB
```

Roughly 88% smaller, mostly from `python:latest` to `python:3.12-slim`.

Behaviour is unchanged, which was the point:

```
$ curl localhost:8099/health
{"status":"ok"}
$ curl localhost:8099/
{"message":"Hello from the API","version":"1.0.0"}
$ docker exec t1 whoami
appuser
$ docker history demo-api:after | grep -c SuperSecret
0
```

Tests:

```
$ pytest app/ -q
2 passed in 0.10s
```

## How I'd know it's down, and how I'd roll back

The ALB already knows before anyone else does, so I'd alarm on it rather than build
something new: a CloudWatch alarm on `UnHealthyHostCount > 0` for the target group, one on
`HTTPCode_ELB_5XX_Count`, and one on `HealthyHostCount < 2` so losing one of the two tasks
pages someone before losing the second one takes the service down. Those go to SNS and
then to whoever is on call. Target response time at p99 catches the slower failure where
everything is technically up and nothing is actually working. With the awslogs config now
in place, a metric filter on ERROR in the log group gives the same signal from the
application's side. For rollback, the fix that matters is already in: images are tagged
with the commit SHA instead of `latest`, so every previous build still exists in ECR and
can be named. The fast path is `terraform apply -var="image_tag=<previous SHA>"`, which
puts the old task definition back and lets ECS roll it out normally, usually a couple of
minutes. If the bad deploy never reaches a healthy state, the circuit breaker with
`rollback = true` does it without anyone being woken up, which is the case I'd rather
optimise for. The thing I'd want but don't have yet is a deployment that fails safe under
partial breakage rather than total breakage, which means CodeDeploy blue/green with a
canary listener rule. That's the "more time" item I'd pick up first.

## What I left alone, and why

These are real problems. I ranked them below the ones above and ran out of time, and I'd
rather be straight about that than pad the diff.

**Remote state in S3.** This is a blocker and I still didn't implement it, which needs
explaining. Creating the bucket means deploying infrastructure, which the brief rules out.
More practically, adding a live `backend "s3"` block makes `terraform init` fail for
anyone without credentials, which would break the exact evidence this assessment asks for.
I left the block in `main.tf` commented out with a note, so the intent is on the record and
the repo still works offline. First thing I'd do with a real account.

**TLS.** The listener is still plain HTTP on port 80, so traffic crosses the internet in
the clear. Fixing it needs an ACM certificate and a domain, neither of which exists here.
The shape is a 443 listener with the cert plus an 80 listener that redirects.

**Private subnets and a NAT gateway.** The tasks still have public IPs. With the security
group split, nothing can reach them anymore, so the practical exposure is mostly closed.
Moving them to private subnets is the correct architecture, but a NAT gateway is about $32
a month per AZ and that's a budget decision rather than an engineering one. VPC endpoints
for ECR and CloudWatch Logs are the cheaper variant. I'd want to ask before picking.

**Autoscaling.** Two tasks is fixed capacity. Fine at this size, wrong the moment traffic
is real.

**Container image scanning in the pipeline.** ECR scan-on-push is enabled, but it reports
after the fact rather than blocking. A Trivy step that fails the build on HIGH or CRITICAL
would stop a bad image from reaching the registry.

**Splitting the Terraform.** One `main.tf` holding network, IAM, ALB, and ECS is fine at
this size and I deliberately didn't restructure it. If this grows I'd split the files and
separate the long-lived network layer from the frequently-deployed service layer, so a
routine deploy can't produce a plan that wants to touch the VPC.
