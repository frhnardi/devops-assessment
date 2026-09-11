# Review

The service works, but a leaked image or a bug in the container would have handed over
the whole AWS account. That's where I spent the time.

## Blockers

**Password committed in four places.** `.env` held a DB password and an API token, and
`.gitignore` didn't cover it. The same password was hardcoded in `app.py`, in
`variables.tf`, and baked into the image with `ENV DB_PASSWORD=`. The Dockerfile one is
worst: `ENV` writes it into the layer, so anyone who can pull from ECR reads it back with
`docker history`. No `.dockerignore` either, so `COPY . .` copied `.env` in as well.

Fix: gone from all four. Terraform creates a Secrets Manager secret and the task pulls it
via `secrets`/`valueFrom`, not `environment` (anything in `environment` is plain text in
the ECS console). Terraform creates the secret container only, not the value, so it never
enters state. Rotate that password, it should be treated as burned.

**Task role had AdministratorAccess.** One role served as both task role and execution
role. They exist for different reasons: the execution role pulls images and writes logs,
the task role is what your code uses at runtime. Merged into one admin role, any RCE in
the container is a full account compromise.

Fix: two roles. Execution role gets the managed ECS policy plus `GetSecretValue` on one
secret ARN. Task role gets nothing, because this app calls no AWS APIs.

**One security group, open to the world, shared by ALB and tasks.** It allowed TCP
0-65535 from 0.0.0.0/0 plus port 22, which does nothing on Fargate. Worse, the same group
was on the ALB and on the tasks, and tasks have public IPs. So the tasks were reachable
directly and the load balancer was decoration.

Fix: two groups. ALB takes 80 from anywhere. Tasks take 8080 from the ALB's group only.

**Container ran the Flask dev server with debug on.** `CMD` ran `app.py` directly, so
`debug=True` was live. The Werkzeug debugger gives an interactive Python console on any
unhandled exception, which is RCE, which chains straight into the admin role above.

Fix: `CMD` now runs gunicorn. I left `debug=True` in `app.py` alone on purpose. Under
gunicorn the `__main__` block never runs, so the debugger can't turn on, and that line is
the local dev entrypoint where debug is the right default. The bug was the container
running the dev server, not the line existing.

**Tests were decorative, and never ran at all.** `continue-on-error: true` meant a red
test still deployed. But running the suite showed it had never worked:

```
ModuleNotFoundError: No module named 'app.app'; 'app' is not a package
no tests collected, 1 error
```

`app/` had no `__init__.py`. The permanently green build was `continue-on-error`
swallowing a collection error.

Fix: added `__init__.py`, dropped the flag, moved tests to their own job that `deploy`
depends on. Now `2 passed`.

**Terraform applied from CI with no remote state.** No `backend` block, but the workflow
ran `terraform apply -auto-approve` on an ephemeral runner. State is lost every run, so
every push tries to rebuild the whole stack and fails on duplicate names. No locking
either. Not fixed, see the last section.

## Should fix

- **`FROM python:latest`**, so no two builds are the same software. Pinned to
  `python:3.12-slim`.
- **`COPY . .` before `pip install`**, so any source change reinstalled every dependency.
  Reordered. Image went 1.64GB to 200MB.
- **Ran as root.** Added a non-root `appuser`.
- **`flask` unpinned.** Pinned flask and gunicorn.
- **No logs at all.** The container definition had no `logConfiguration`, so nothing
  reached CloudWatch. This is why "how would you know it's down" had no answer. Added
  awslogs plus a log group with 30 day retention.
- **Health check hit `/` instead of `/health`.** The target group had no `health_check`
  block. It worked by luck because `/` returns 200.
- **No circuit breaker**, so a broken image crash loops forever. Enabled with
  `rollback = true`.
- **`desired_count = 1`** across two AZs, so no redundancy and a gap on every deploy.
  Raised to 2 with a health check grace period.
- **Everything tagged `latest`.** The task definition never changes when the image does,
  and rollback has nothing to point at. Now tagged with the commit SHA, `image_tag` has no
  default, ECR set to `IMMUTABLE`.
- **Static AWS keys in CI.** Replaced with OIDC role assumption.
- **`docker push` had no `ecr get-login-password`**, so the step was broken, not just
  unsafe. This pipeline had never run end to end.
- **No concurrency group or `permissions` block.** Added both.
- **Redundant `force-new-deployment`**, which was papering over the `latest` problem and
  causing drift. Removed.
- **Hardcoded AZ suffixes.** Switched to the `aws_availability_zones` data source.

## Nice to have

No tags on any resource (added `default_tags`), no outputs (added), no ECR lifecycle
policy, missing `depends_on` between the service and the listener, no ALB access logs or
VPC flow logs, actions pinned to tags rather than SHAs. `/health` also returns 200
unconditionally, which is fine now but can't tell "process is up" from "process works".

One note on the evidence this asks for: I ran `fmt -check` and `validate` on the untouched
starter and both passed, on a config with `AdministratorAccess` and a wide open security
group. `validate` checks syntax and schema, not whether the config is a good idea. I added
a tfsec step to the pipeline for that.

## Show your work

```
$ terraform fmt -check          # exit 0
$ terraform validate
Success! The configuration is valid.

$ terraform plan -var="image_tag=abc1234"
Plan: 22 to add, 0 to change, 0 to destroy.

$ docker images demo-api
TAG      SIZE
before   1.64GB
after    200MB

$ pytest app/ -q
2 passed in 0.10s
```

Behaviour unchanged, which was the point:

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

## How I'd know it's down, and how I'd roll back

The ALB knows before anyone else, so I'd alarm on it rather than build something new:
CloudWatch alarms on `UnHealthyHostCount > 0`, `HTTPCode_ELB_5XX_Count`, and
`HealthyHostCount < 2` so losing one task pages someone before losing the second one takes
the service down. Add p99 target response time for the case where everything is up and
nothing works, and a metric filter on ERROR in the log group now that logs exist. For
rollback, the fix is already in: images are tagged with the commit SHA, so every previous
build still exists in ECR and can be named. Run `terraform apply -var="image_tag=<old
SHA>"` and ECS rolls the previous task definition back in a couple of minutes. If the bad
deploy never goes healthy, the circuit breaker with `rollback = true` handles it without
waking anyone, which is the case worth optimising for. What's missing is failing safe
under partial breakage, which means CodeDeploy blue/green with a canary listener rule.

## Left alone on purpose

**Remote state in S3.** Still a blocker. Creating the bucket means deploying, which the
brief rules out, and a live `backend` block makes `terraform init` fail for anyone without
credentials, which breaks the evidence above. Left commented in `main.tf` with a note.
First thing I'd do with a real account.

**TLS.** Listener is still plain HTTP on 80. Needs an ACM cert and a domain, neither of
which exists here. Shape is a 443 listener plus an 80 redirect.

**Private subnets and NAT.** Tasks still have public IPs. With the security group split
nothing can reach them, so the practical exposure is mostly closed. Moving them is the
correct architecture but a NAT gateway is roughly $32 a month per AZ, which is a budget
call, not an engineering one. VPC endpoints are the cheaper variant.

**Autoscaling.** Two tasks is fixed capacity. Fine at this size, wrong once traffic is real.

**Image scanning that blocks.** ECR scan-on-push is on, but it reports after the fact. A
Trivy step failing the build on HIGH or CRITICAL would stop a bad image reaching the
registry.

**Splitting the Terraform.** One `main.tf` is fine at this size and I didn't restructure
it. If it grows I'd separate the long-lived network layer from the service layer, so a
routine deploy can't produce a plan that wants to touch the VPC.
