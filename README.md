# smtp-relay

An authenticated, TLS-only Postfix relay that runs **inside** the Kubernetes cluster. Workloads in
the cluster (Grafana, n8n, helpdesk, ...) log in to it and hand it mail. The relay passes the mail
to Amazon SES, which signs it for `faultycloud.xyz` and delivers it.

```
pods in any namespace ──(587 STARTTLS / 465 TLS + SASL login)──▶ smtp-relay.smtp-relay.svc
                                                                      │
                          ┌───────────────────────────────────────────┘
                          └──(587 STARTTLS, verified cert + SES SMTP creds)──▶ email-smtp.<region>.amazonaws.com ──▶ internet
```

The relay is reachable only inside the cluster: there's a ClusterIP Service, no LoadBalancer or
NodePort, and a NetworkPolicy that admits only cluster pods.

**Getting it working, in order:**
1. [Set up SES and DNS](#part-1-amazon-ses-and-dns-manual). This is manual and has waiting periods,
   so start it first.
2. [Deploy the relay](#part-2-deploy-the-relay).
3. [Test it](#part-3-test).
4. [Point apps at it](#part-4-point-apps-at-the-relay).

## What it enforces

| Side | Behaviour |
|---|---|
| Inbound | Ports 587 (STARTTLS required) and 465 (implicit TLS), TLS 1.2+. AUTH PLAIN/LOGIN is offered only after TLS. No login means no relay (`554 Access denied`). Port 25 is off. |
| Network | Ingress on 587/465 from cluster pods only. Egress is DNS, plus 587/465 to public IPs (private ranges blocked). |
| Users | Stored in a Secret (`user[@realm]:password` per line) and loaded into a sasldb when the pod starts. |
| Outbound | `smtp_tls_security_level=secure`: the SES certificate must verify against the system CAs, otherwise mail stays queued. SASL login to SES. |
| Queue | Kept on a PVC, so deferred mail survives pod restarts and deletion, and retries automatically. |
| Certs | A private CA run by cert-manager in the namespace issues the server cert for the `*.svc` names. Postfix reloads within 5 minutes after a renewal. |
| Logs | Go to stdout (`kubectl logs`). Probes don't write to the log. |

## Cluster requirements

The manifests are already set for `muses`. Check these if you deploy somewhere else.

| Need | Why | Check |
|---|---|---|
| cert-manager | Issues the private CA and the server cert (`k8s/10-certificate.yaml`) | `kubectl get pods -n cert-manager` |
| A CNI that enforces NetworkPolicy (Calico on `muses`) | Otherwise `70-networkpolicy.yaml` is silently ignored | `kubectl get pods -n calico-system` |
| CoreDNS pods labelled `k8s-app=kube-dns` | The egress policy allows DNS by that label | `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| A StorageClass for the queue PVC | `muses` has no default class; `40-pvc.yaml` sets `rook-ceph-ssd` | `kubectl get sc` |
| Outbound internet on 587 | To reach SES | |
| An image built for the nodes' architecture | `muses` nodes are **amd64**; an Apple Silicon Mac builds arm64 by default | `kubectl get nodes -o wide` |

---

## Part 1: Amazon SES and DNS (manual)

Allow about an hour of hands-on time. DNS verification usually finishes within minutes but can
take up to 72 hours. Production access is usually granted within 24 hours. You can deploy and test
the relay (parts 2 and 3) while you wait.

### 1.1 Choose the region (decide once)

Everything in SES is **per region**: the domain identity, the SMTP credentials and the sandbox
status. Credentials made in one region return `535 Authentication Credentials Invalid` in any other.

- Pick one, e.g. **US East (Ohio) = `us-east-2`**. Select it in the region picker at the top right
  of the AWS console before every step below.
- Its SMTP endpoint is `email-smtp.<region>.amazonaws.com`, e.g. `email-smtp.us-east-2.amazonaws.com`.
- ✅ **Done when:** you've written the region down. If it isn't `us-east-2`, change `RELAY_HOST` in
  `k8s/30-configmap.yaml` to match.

### 1.2 Create the domain identity

1. **Amazon SES → Configuration → Identities → Create identity.**
2. Identity type: **Domain**. Domain: `faultycloud.xyz`.
3. Check **Use a custom MAIL FROM domain**. Subdomain: `bounce` (giving `bounce.faultycloud.xyz`).
   Behavior on MX failure: **Use default MAIL FROM domain**.
4. **Verifying your domain → Advanced DKIM settings**: Easy DKIM, **RSA_2048_BIT**, DKIM signatures
   enabled. Leave "Publish DNS records to Route53" unchecked, because the zone is on Cloudflare.
5. **Create identity.** The identity page now shows a **Publish DNS records** panel: three DKIM
   CNAMEs plus the MAIL FROM MX and TXT records. Keep the tab open for the next step.

### 1.3 Add the DNS records in Cloudflare

In Cloudflare, open **faultycloud.xyz → DNS → Records → Add record** for each row below. Rules:

- **Proxy status: DNS only** (grey cloud) on every record. A proxied (orange) CNAME won't verify.
- In the **Name** field, enter only the part before `.faultycloud.xyz`. Cloudflare appends the zone.
  If SES shows `abc123._domainkey.faultycloud.xyz`, type `abc123._domainkey`.
- Copy the token values from the SES panel; don't retype them.

| Type | Name | Content / target | Extra field | Purpose |
|---|---|---|---|---|
| CNAME | `<token1>._domainkey` | `<token1>.dkim.amazonses.com` | | DKIM key 1 |
| CNAME | `<token2>._domainkey` | `<token2>.dkim.amazonses.com` | | DKIM key 2 |
| CNAME | `<token3>._domainkey` | `<token3>.dkim.amazonses.com` | | DKIM key 3 |
| MX | `bounce` | `feedback-smtp.<region>.amazonses.com` | Priority `10` | Bounces for the MAIL FROM domain |
| TXT | `bounce` | `v=spf1 include:amazonses.com ~all` | | SPF for the MAIL FROM domain |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:<an address you read>` | | DMARC (SES doesn't show this one) |

Check before moving on. Each command should print the value you entered (cached results can lag a
few minutes):

```bash
dig +short CNAME <token1>._domainkey.faultycloud.xyz
dig +short MX bounce.faultycloud.xyz
dig +short TXT bounce.faultycloud.xyz
dig +short TXT _dmarc.faultycloud.xyz
```

- ✅ **Done when:** the identity's **Identity status** is **Verified**, **DKIM configuration** is
  **Successful**, and the **Custom MAIL FROM domain** tab shows **Success**. SES emails the AWS
  account owner when these change.
- If an existing `faultycloud.xyz` TXT record has `v=spf1`, leave it alone. The SPF record goes on
  `bounce`, not on the apex.
- Once a week or two of DMARC reports look clean, tighten `_dmarc` to `p=quarantine`.

### 1.4 Create SMTP credentials

1. **Amazon SES → SMTP settings** (in the same region) → **Create SMTP credentials**.
2. Accept the default IAM user name (or name it `ses-smtp-smtp-relay`) → **Create user**.
3. The next screen shows an **SMTP user name** (starts with `AKIA`) and an **SMTP password**, once
   only. Download the `.csv` or copy both into a password manager right away.

The SMTP password is **derived from**, and different from, the IAM user's secret access key. Use the
one on this screen. Putting the IAM secret key in the relay gives `535 Authentication Credentials
Invalid`.

- ✅ **Done when:** both values are stored somewhere safe. They go into the cluster in step 2.2.

### 1.5 Request production access (leave the sandbox)

A new SES account is in the **sandbox**: it can send only **to** verified addresses or domains, at
up to 200 messages a day.

1. **Amazon SES → Account dashboard → Request production access** (or "Get set up").
2. Mail type: **Transactional**. Website URL: `https://faultycloud.xyz`. Use case: say it's alerts
   and notifications from self-hosted apps (Grafana, n8n, helpdesk) to known recipients, low volume,
   with bounces and complaints handled.
3. Submit. AWS replies by email, usually within 24 hours, sometimes with follow-up questions.

To test before approval comes through: **Identities → Create identity → Email address**, enter the
recipient you'll test with, and click the link in the email AWS sends.

- ✅ **Done when:** the Account dashboard shows **Production access** with a daily sending quota.

### SES checklist

- [ ] Region chosen; `RELAY_HOST` in `k8s/30-configmap.yaml` matches it
- [ ] `faultycloud.xyz` identity: status Verified, DKIM Successful, MAIL FROM Success
- [ ] Cloudflare: 3 DKIM CNAMEs, `bounce` MX and TXT, `_dmarc` TXT, all DNS only
- [ ] SMTP user name and password saved
- [ ] Production access granted, or the test recipient verified as an identity

---

## Part 2: Deploy the relay

Run everything from the repo root.

### 2.1 Build and push the image (only when `image/` changes)

```bash
docker buildx build --platform linux/amd64 -t docker.io/bbrietzke/smtp-relay:1.0.0 --push image/
```

`docker.io/bbrietzke/smtp-relay:1.0.0` is already pushed. When you build a new version, bump the tag
here and in `k8s/50-deployment.yaml`.

### 2.2 Create the namespace and secrets

```bash
kubectl apply -f k8s/00-namespace.yaml

# SES SMTP credentials from step 1.4. Leading space keeps it out of shell history in zsh/bash
# when HIST_IGNORE_SPACE / HISTCONTROL=ignorespace is set; otherwise clear history after.
 kubectl -n smtp-relay create secret generic smtp-relay-upstream \
   --from-literal=RELAY_USER='AKIA...' --from-literal=RELAY_PASSWORD='<SES SMTP password>'
```

Next, the logins that apps use to authenticate to the relay. Give each app its own login, so you can
see in the logs who sent what and revoke one without touching the others. Build the file outside
the repo:

```bash
umask 077
for app in grafana n8n helpdesk kanban; do
  printf '%s@faultycloud.xyz:%s\n' "$app" "$(openssl rand -base64 24)"
done > ~/smtp-relay-users.txt
cat ~/smtp-relay-users.txt          # copy each app's password into that app's config (part 4)

kubectl -n smtp-relay create secret generic smtp-relay-users --from-file=users=$HOME/smtp-relay-users.txt
```

The file format is one `user@realm:password` per line. A bare `user:password` gets the realm
`faultycloud.xyz` added (`SASL_REALM`). The username can't contain `:`; the password can. Lines
starting with `#` are ignored. Store the file in a password manager and delete it afterwards. The
secret is the copy of record.

### 2.3 Apply

```bash
kubectl apply -k k8s/
kubectl -n smtp-relay get certificate                  # smtp-relay-ca and smtp-relay-tls: READY True
kubectl -n smtp-relay rollout status deploy/smtp-relay
kubectl -n smtp-relay logs deploy/smtp-relay
```

A healthy start looks like this, with no warnings:

```
entrypoint: loaded 4 SASL user(s); realm for bare usernames: faultycloud.xyz
entrypoint: relaying via [email-smtp.us-east-2.amazonaws.com]:587 as smtp-relay.faultycloud.xyz
postfix/postlog: starting the Postfix mail system
... postfix/master[...]: daemon started -- version 3.10.13, configuration /etc/postfix
```

The pod sits in `ContainerCreating` for a few seconds while cert-manager issues `smtp-relay-tls`.
That's normal.

### Changing secrets later

Both secrets are read only at pod start, so restart after changing either one:

```bash
# replace a secret in place (same flags as when creating it), then restart
kubectl -n smtp-relay create secret generic smtp-relay-users --from-file=users=$HOME/smtp-relay-users.txt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n smtp-relay rollout restart deploy/smtp-relay
```

---

## Part 3: Test

[swaks](https://github.com/jetmore/swaks) sends one message and prints the whole SMTP conversation.
Run it from a throwaway pod, since the relay isn't reachable from outside the cluster. Set `PW` to
the `grafana@faultycloud.xyz` password from `~/smtp-relay-users.txt`, and `TO` to a real recipient
(while in the SES sandbox, one you verified in step 1.5):

```bash
PW='<grafana password>'; TO='you@example.com'
CA="$(kubectl -n smtp-relay get secret smtp-relay-ca -o jsonpath='{.data.ca\.crt}' | base64 -d)"
kubectl run swaks -n default --rm -it --restart=Never --image=debian:trixie-slim \
  --env="CA=$CA" --env="PW=$PW" --env="TO=$TO" -- sh -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends swaks libnet-ssleay-perl libio-socket-ssl-perl >/dev/null
  printf "%s\n" "$CA" > /ca.crt
  swaks --server smtp-relay.smtp-relay.svc --port 587 --tls --tls-verify --tls-ca-path /ca.crt \
    --auth PLAIN --auth-user grafana@faultycloud.xyz --auth-password "$PW" \
    --from alerts@faultycloud.xyz --to "$TO"'
```

It takes about 20 seconds (installing swaks), then ends with `250 2.0.0 Ok: queued as ...`. That
means **the relay** accepted it. Whether **SES** accepted it is in the relay log:

```bash
kubectl -n smtp-relay logs deploy/smtp-relay | grep -E 'Verified TLS|status='
```

| You see | Meaning |
|---|---|
| `Verified TLS connection established to email-smtp...` then `status=sent (250 Ok ...)` | ✅ Delivered to SES. Check the inbox. |
| `status=deferred (SASL authentication failed; ... 535 Authentication Credentials Invalid)` | Everything up to SES works; the credentials are wrong (IAM key instead of SMTP password, wrong region, typo). Fix the secret, restart, and the queued mail retries by itself. |
| `status=bounced (... 554 Message rejected: Email address is not verified ...)` | Sandbox: the recipient (or From domain) isn't verified in this region. |
| `status=deferred (... Server certificate not verified)` | The SES cert didn't verify. Mail stays queued by design. |
| `status=deferred (connect to ... Operation timed out)` | Egress blocked: check `RELAY_HOST` and the NetworkPolicy. |

The `535` row is a useful check before you have SES credentials. With placeholder values in
`smtp-relay-upstream`, a test that reaches it shows that DNS, egress and TLS to SES all work.
Before you put the real credentials in, clear the queued test mail so it isn't sent for real:
`kubectl -n smtp-relay exec deploy/smtp-relay -- postsuper -d ALL`.

Once a message arrives, open its headers (Gmail: **⋮ → Show original**) and check:
- `DKIM: 'PASS' with domain faultycloud.xyz`
- `SPF: PASS` with `bounce.faultycloud.xyz`
- `DMARC: 'PASS'`

---

## Part 4: Point apps at the relay

### Settings every app needs

| Setting | Value |
|---|---|
| Host | `smtp-relay.smtp-relay.svc` |
| Port / security | `587` + STARTTLS (preferred), or `465` + implicit TLS/SSL |
| Username / password | that app's line from `~/smtp-relay-users.txt` |
| From address | must be `@faultycloud.xyz`, or SES rejects the message |
| CA | `smtp-relay-ca` (below), or the app's "skip TLS verify" option |

### Trusting the relay's certificate

The relay's certificate comes from the in-namespace private CA, so apps that verify TLS need that CA.
Copy it into the app's namespace:

```bash
kubectl -n smtp-relay get secret smtp-relay-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/smtp-relay-ca.crt
kubectl -n <app-namespace> create configmap smtp-relay-ca --from-file=ca.crt=/tmp/smtp-relay-ca.crt
```

Mount that ConfigMap in the app at `/etc/smtp-relay-ca`, then tell the app's runtime to trust it.
Both of these add the CA **alongside** the public ones. Tested against the live relay; public certs
still verified afterwards.

| Runtime | Environment variable |
|---|---|
| Node.js (n8n) | `NODE_EXTRA_CA_CERTS=/etc/smtp-relay-ca/ca.crt` |
| Go (Grafana) | `SSL_CERT_DIR=/etc/ssl/certs:/etc/smtp-relay-ca` |

The CA is valid for 10 years and keeps its key (`rotationPolicy: Never`), so copies keep working
when the server cert renews every 90 days. Skipping verification instead still encrypts the
connection and still requires the login; it just doesn't prove which server answered.

### Grafana (`kube-prometheus-stack` release `prometheus` in `monitoring`)

Add this to the chart values, then `helm upgrade prometheus prometheus-community/kube-prometheus-stack -n monitoring -f <values>`.
The keys follow the Grafana subchart's documented values, but this hasn't been applied to your
cluster.

```yaml
grafana:
  grafana.ini:
    smtp:
      enabled: true
      host: smtp-relay.smtp-relay.svc:587
      from_address: grafana@faultycloud.xyz
      from_name: Grafana
      startTLS_policy: MandatoryStartTLS
  smtp:
    existingSecret: grafana-smtp        # kubectl -n monitoring create secret generic grafana-smtp \
    userKey: user                       #   --from-literal=user=grafana@faultycloud.xyz --from-literal=password='...'
    passwordKey: password
  env:
    SSL_CERT_DIR: /etc/ssl/certs:/etc/smtp-relay-ca
  extraConfigmapMounts:
    - name: smtp-relay-ca
      configMap: smtp-relay-ca
      mountPath: /etc/smtp-relay-ca
      readOnly: true
```

Test it in **Alerting → Contact points → (email) → Test**.

### n8n (release `n8n` in `n8n`)

n8n has two separate SMTP settings:
- **User-management mail** (invites, password resets) uses these environment variables. Set them
  through the chart's environment/extra-env values; check the chart's `values.yaml` for the exact key.
  ```
  N8N_EMAIL_MODE=smtp
  N8N_SMTP_HOST=smtp-relay.smtp-relay.svc
  N8N_SMTP_PORT=587
  N8N_SMTP_SSL=false            # false = STARTTLS on 587; true only for 465
  N8N_SMTP_USER=n8n@faultycloud.xyz
  N8N_SMTP_PASS=<from a secret>
  N8N_SMTP_SENDER=n8n@faultycloud.xyz
  NODE_EXTRA_CA_CERTS=/etc/smtp-relay-ca/ca.crt
  ```
- **"Send Email" workflow nodes** use an SMTP credential created in the n8n UI: same host, port,
  user and password, with SSL/TLS off for 587. `NODE_EXTRA_CA_CERTS` covers these too.

### helpdesk and kanban

- **helpdesk** currently sends to `mailpit:1025` with only `SMTP_HOST`, `SMTP_PORT` and `SMTP_FROM`
  set. It must also support an SMTP **username/password** and **STARTTLS** before it can use the
  relay, which rejects mail without both. Check the app for the setting names, or add them.
- **kanban** already uses `MAIL_MODE=smtp`, `SMTP_PORT=587`, `SMTP_TLS=starttls`. Set its host to
  `smtp-relay.smtp-relay.svc`, its user and password to the `kanban` login, and a
  `@faultycloud.xyz` From. Then make the app trust `smtp-relay-ca` (how depends on its language;
  see the table above).

---

## Operations and troubleshooting

- **Queue**: `kubectl -n smtp-relay exec deploy/smtp-relay -- postqueue -p` lists deferred mail,
  `postqueue -f` retries it now, `postsuper -d <queue-id>` (or `ALL`) deletes it. Deferred mail
  retries on its own for 5 days, then bounces to the sender.
- **Who sent what**: `kubectl -n smtp-relay logs deploy/smtp-relay | grep sasl_username`.
- **Pod stuck `ContainerCreating`**: a secret is missing (`smtp-relay-tls` not issued yet,
  `smtp-relay-users` or `smtp-relay-upstream` not created). See `kubectl -n smtp-relay describe pod -l app.kubernetes.io/name=smtp-relay`.
- **Pod `CrashLoopBackOff`**: `kubectl -n smtp-relay logs deploy/smtp-relay --previous`. The
  entrypoint says what's missing (`no valid users`, `RELAY_PASSWORD must be set`, ...).
  `exec format error` means the image was built for the wrong architecture.
- **PVC `Pending`**: no `storageClassName` and no default class.
- **App gets `535` from the relay**: wrong app login, or a bare username whose realm doesn't match.
  Use the full `name@faultycloud.xyz`.
- **App gets `554 Access denied` from the relay**: the app didn't log in. It must use AUTH.
- **App can't connect at all**: check it's in this cluster and using `smtp-relay.smtp-relay.svc`
  on 587/465. To limit which namespaces can connect, add a label match to the ingress
  `namespaceSelector` in `70-networkpolicy.yaml`, e.g. `kubernetes.io/metadata.name: monitoring`.
- **Upstream on 465**: set `RELAY_PORT=465` and `RELAY_TLS_WRAPPER=yes`.
- **Scaling**: one replica, because the queue lives on an RWO volume. For HA, run several replicas
  with `emptyDir` queues and accept that queued mail is lost when a pod dies.
- **Hardening**: the container drops all capabilities except the few Postfix's root master needs to
  drop privileges, runs with `allowPrivilegeEscalation: false`, and the TLS key is mounted `0400` at
  `/run/secrets/smtp-tls`. Keep that mount outside `/etc/postfix`, where `postfix check` rejects
  the secret-volume layout.

## Tested

On `muses` (Kubernetes 1.37, Calico, rook-ceph, cert-manager v1.21):

- **Parts 2 and 3, run exactly as written**, with the real `k8s/` manifests in the `smtp-relay`
  namespace. Placeholder SES credentials gave verified TLS to `email-smtp.us-east-2.amazonaws.com`,
  then `535` with the mail held in the queue.
- With an in-cluster fake upstream:
  - delivery on 587 and 465 from another namespace, with the certificate verified against
    `smtp-relay-ca`
  - rejection without login and with a wrong password
  - no access from outside the cluster
  - NetworkPolicy egress enforcement
  - queued mail surviving pod deletion
  - Postfix reloading after a cert-manager renewal
- Node `NODE_EXTRA_CA_CERTS` and Go `SSL_CERT_DIR` trusting `smtp-relay-ca` from a pod in another
  namespace.

Not tested:
- Part 1 (needs your AWS and Cloudflare accounts).
- A real SES delivery.
- The Grafana, n8n, helpdesk and kanban configurations in Part 4. None of them were changed on
  the cluster.
