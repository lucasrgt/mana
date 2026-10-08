# Mana Runtime

Explicit release configuration for Ash/Phoenix consumers. Local dependency
`{:mana_runtime, path: "../../framework/ash/runtime"}`. `load!` starts no processes,
prepares no fixtures and does not depend on the Moments runner.

In `config/runtime.exs`, in the `config_env() == :prod` branch, use
`runtime = Mana.Runtime.load!()` and apply `runtime.repo`, `runtime.endpoint`,
`runtime.web_origin` and `runtime.token_signing_secret` to the app's configuration.
The consumer still owns the Repo, Endpoint, authentication and migrations.

| Variable | Contract |
| --- | --- |
| `DATABASE_URL` | postgres/postgresql URL with a database; no query/fragment |
| `DATABASE_SSL` | `require` by default, with a verified certificate; `disable` only on loopback for local proofs |
| `DATABASE_CA_CERT` | Optional PEM; when absent, the system authorities are used |
| `PUBLIC_ORIGIN` | The API's public HTTPS origin |
| `WEB_ORIGIN` | One authorised HTTPS frontend origin |
| `SECRET_KEY_BASE` | Phoenix secret with at least 64 bytes |
| `TOKEN_SIGNING_SECRET` | A distinct secret with at least 32 bytes |
| `BIND_ADDRESS` | Literal IP; default `127.0.0.1` |
| `PORT` | Internal HTTP port; default 4000 |
| `POOL_SIZE` | Connections per instance; default 10, between 1 and 100 |
| `TRUSTED_PROXY_IPS` | Up to 16 comma-separated literal IPs, or `fly` (client in `Fly-Client-IP`, only with the port behind Fly's proxy); absent trusts no proxy |

HTTP origins are only accepted on loopback. The endpoint listens on internal HTTP:
public TLS needs a proxy/ingress configured by the operator. An HTTPS origin in the
configuration installs no certificates and proves no transport. Use independent
random secrets delivered by the environment/secret manager; never in code or command
arguments. The minimum length does not measure entropy.

## One explicit HTTPS edge

The consumer can apply `runtime.trusted_proxy_ips` to its OTP app's
`:trusted_proxy_ips` configuration and install
`plug(Mana.Runtime.Proxy, otp_app: :my_app)` before CORS, limits and routing. The
plug compares the socket's real peer with that list, then delegates IP/scheme to the
native `Plug.RewriteOn`. It never implicitly trusts private/loopback networks,
forwarded Host, `Forwarded` or a `conn.remote_ip` already rewritten.

This configuration supports **one edge proxy**: it must replace `X-Forwarded-For`
with a single observed IP and `X-Forwarded-Proto` with the observed scheme. Chains,
duplicate values or incomplete metadata from the trusted proxy get a 400.
Connections outside the list do not have their headers applied. Internal probes
without either header keep the connection's identity. A load balancer/CDN in front
requires reviewing the topology; do not add whole networks or trust headers
indiscriminately to make it work.

Property: inside this plug, an unauthorised peer cannot choose the IP used by the
rewrite (`guaranteed`, with negative proofs of the mechanism). Configuring the list,
filtering at the edge and closing direct access to the API are `reviewed` in the
deployment. The default is to trust nothing. Another plug can rewrite `remote_ip`
later: that escape is outside the guarantee. The consumer's Hammer limiter stays
local per node.

An edge such as Caddy must replace those headers explicitly. The guidance follows the
[Plug.RewriteOn contract](https://plug.hexdocs.pm/Plug.RewriteOn.html) and the
[Caddy proxy headers](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#headers).

## Dependency probes

`{Mana.Runtime.Probe, name: MyApp.Probes}` adds a `Task.Supervisor` to the OTP tree,
with at most four concurrent probes (`max_children` is configurable).
`Mana.Runtime.Probe.ready?(MyApp.Probes, fn -> ... end)` only accepts `true` as
success. A timeout (1 s by default), a failure or saturation return `false`. Worker
shutdown has up to 100 ms of grace before a forced stop. The probe must be read-only:
never run business actions in it.

The app chooses the dependency and keeps the HTTP contract. A typical setup: `/livez`
says the endpoint is alive; `/readyz` queries the database and returns 503 when it
cannot serve. Responses are not cached and carry no credentials or internal
diagnostics. The probe creates no other database pool. The driver's timeout is still
useful but does not replace the process limit: query cancellation can also be held
up on the network.

When consuming it as a local dependency, add `runtime/lib` and `runtime/mix.exs` to the
Moments service's `watch` list, next to the app's sources. The runner uses that
explicit list to decide compilation and to tie evidence to the Elixir code; it does
not resolve Mix dependencies automatically.

## Optional SMTP email

`Mana.Runtime.Mail.load!()` returns `mode`, `mailer` and `from`. The consumer installs
Swoosh and `gen_smtp`, applies `mailer` to its `MyApp.Mailer` configuration and keeps
templates, links and the queue in the app. Mana only defines the safe configuration;
it creates no other SMTP client.

| Variable | Contract |
| --- | --- |
| `MAIL_TRANSPORT` | `disabled` by default; `smtp` enables it and requires the fields below |
| `SMTP_HOST` | The relay's hostname, without scheme, credentials or path |
| `SMTP_PORT` | 587 by default; 1 to 65535 |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | Required credentials, kept untrimmed |
| `MAIL_FROM` | The sender's plain address, authorised at the provider |
| `SMTP_CA_CERT` | Optional PEM path; when absent, the system authorities are used |

The supported transport is **mandatory STARTTLS**, with mandatory authentication,
chain and hostname validation and TLS 1.2/1.3. There is no downgrade to plaintext and
no mode that ignores certificates, not even on loopback. Port 465 with implicit TLS is
not implemented. The options follow the
[official Swoosh adapter](https://swoosh.hexdocs.pm/Swoosh.Adapters.SMTP.html).
Invalid values raise errors naming the variable, without repeating its content.
`load!` does not validate access to the provider: that needs a real delivery.

There is a 5 s connection timeout and no internal client retry. The consumer must
bound the total duration and use its durable queue for retries (for example, a worker
with a 30 s limit and five attempts). SMTP acceptance does not prove arrival in the
inbox; a lost response can also cause a duplicate delivery on retry. Exactly-once
delivery is not promised.

The external provider,
the sender's DNS and deliverability remain the deployment's responsibility.

## Operational metrics

`Mana.Runtime.Metrics` provides `Telemetry.Metrics` definitions for native
Bandit/Ecto/Oban events and a Peep child spec. The application declares the reporter
name, endpoint, Repo event, Oban instance and allowed queues. Metrics carry no SQL,
URLs, arguments or credentials. Histograms are aggregated on arrival, with bounded
labels; interrupted collection does not pile up raw samples.

`Mana.Runtime.MetricsPlug` serves `/metrics`, disabled without `METRICS_TOKEN`. Block
that path at the public edge and provision the scrape token separately. The framework creates no reporter/process automatically.

The alert rules, Alertmanager and blackbox configuration serve any consumer whose
scrape is called `job="mana"` (and `mana-health`/`mana-alertmanager`):
[observability/](observability/), with `promtool` scenarios in `alerts.test.yml`. The
consumer only supplies its scrape targets and the edge.
