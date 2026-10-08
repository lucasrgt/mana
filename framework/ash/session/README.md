# Mana Session — Ash transport for Flutter clients

The library behind the HTTP contract used by `framework/flutter/ash_session`. The
application declares the AshAuthentication resources, policies and storage; the
library composes the existing authentication and provides JSON, identity, CORS and
credential admission. It does not sign JWTs nor implement its own password hashing.

```elixir
# mix.exs, adjust the path to the consumer
{:mana_session, path: "../../framework/ash/session"}
```

## Explicit composition

A local wrapper keeps the routes readable and names the application's resources:

```elixir
defmodule MyAppWeb.Session do
  def init(action), do: Mana.Session.init(action: action,
    user: MyApp.Accounts.User, token: MyApp.Accounts.Token)
  defdelegate call(conn, options), to: Mana.Session
end

defmodule MyAppWeb.Identity do
  def init(_), do: [otp_app: :my_app, user: MyApp.Accounts.User]
  defdelegate call(conn, options), to: Mana.Session.Identity
end
```

Register `Accounts` in `config :my_app, ash_domains: [...]` and supervise
`{AshAuthentication.Supervisor, otp_app: :my_app}`. The user resource must use
`AshAuthentication`, the `:password` strategy, an `email` identity, a UUID `id` and
the `:token` session metadata; the token resource uses
`AshAuthentication.TokenResource`. This contract is opinionated for email/password
sessions; it does not advertise OAuth, multitenancy or email confirmation the app
has not implemented.

The expected actions follow AshAuthentication: `sign_in_with_password` and
`register_with_password`. Keep passwords sensitive and untrimmed, the confirmation
validation and the library's hashing/token-generation changes. Storing all tokens
and requiring their presence for authentication, and the session lifetime, are
options of the resource, not hidden in the transport. Domain and owner policies
stay in the app.

| Method and path | Wrapper action | Contract |
| --- | --- | --- |
| POST `/auth/sign-in` | `:sign_in` | Email/password → token, userId, email, expiresAt |
| POST `/auth/sign-up` | `:sign_up` | Email/password/confirmation → session, or rejection |
| GET `/auth/session` | `:show` | Identity and expiry, without reissuing a token |
| DELETE `/auth/session` | `:sign_out` | Revokes the persisted token; 204 response |

`show`, `sign_out` and the data routes **require** the Identity pipeline. The
resolver accepts exactly one non-empty Bearer under 8192 bytes. It delegates
verification, purpose, expiry, revocation and subject resolution to
AshAuthentication. It only accepts the configured authenticatable resource in the
assignment matching its subject; the internal token record never becomes an actor.
Session responses and identity rejections use `Cache-Control: no-store`.

## Admission and endpoint

The app provides its Hammer module, for example `use Hammer, backend: :ets,
algorithm: :fix_window_per_key`, and supervises it. Configure
`Mana.Session.Throttle` with `scope`, `otp_app` and `limiter`:

- `:ip` before `Plug.Parsers`: 30 attempts per minute on sign-in/sign-up;
- `:account` in those routes' pipeline: 6 per minute, normalised email and an HMAC key;
- budget exceeded: 429 with Retry-After; counter unavailable: 503.

The HMAC secret comes from `config :my_app, :token_signing_secret`. The IP comes
from `conn.remote_ip`, without trusting forwarded headers automatically. The example
uses ETS per instance; distributed limits and a proxy policy need their own
deployment and verification. The library does not promise them.

`Mana.Session.Cors` receives `otp_app` and reads `:web_origin`, allowing only that
origin and exposing Retry-After. CORS does not replace authentication. The endpoint
should limit the JSON body (16 KiB is plenty) before dispatching to the
transport.

`Mana.Session.OpenApi.modify/3` normalises the resources with `Contracts.OpenApi`
and adds the session contract. Use the same modifier for the export and for the
endpoint that feeds the Dart client. In Flutter, inject the generated client into
`AshSession`; persistence, stale responses, 401, logout and waiting on 429 already
belong to the `ash_session` library.

To export the same session-route contract, the consumer uses
`mix contracts.export MyApp.Domain /api output.json Mana.Session.OpenApi`. The
optional argument chooses the `modify/3` module; three arguments keep using
`Contracts.OpenApi`. The deployment URL in `servers` may differ from the served
contract; operations and schemas must match.

In the Moments service, add `framework/ash/session/lib` and
`framework/ash/session/mix.exs` to the `watch` inventory and restart the supervisor
after changing its definition.

References for the dependency:
[AshAuthentication — setup](https://ash-authentication.hexdocs.pm/get-started.html)
and [Bearer helpers](https://ash-authentication.hexdocs.pm/AshAuthentication.Plug.Helpers.html).

## Optional recovery

`Mana.Session.Recovery` adds two Plug actions:

- `:request`: `POST /auth/request-password-reset` takes `email`, enqueues before
  looking up the account and answers `202` for both existing and missing
  identities. The app provides `enqueue: {Module, :function}`; unconfigured delivery
  answers `503`. Invalid inputs answer `422`; the routes take part in the library's
  IP/account limits. Constant time is not claimed.
- `:reset`: `POST /auth/reset-password` takes `token`, `password` and
  `passwordConfirmation`. It returns `204` without a session; the person must sign in
  again. An invalid/used token or a refused password returns `422`.

The resource defines `password.resettable`, the password policy on update and the
`log_out_everywhere` add-on. `Mana.Session.PasswordReset` requires the User/Token
resources on the same AshPostgres Repo, including for reads. It identifies the
account from the verified JWT, locks the row inside the transaction, calls the
library's reset (which revalidates the token) and runs `log_out_everywhere`
explicitly before the commit. Two concurrent processes therefore cannot reset with
the same token. Revocation includes the session the action generates internally;
it never reaches the client. The Token needs a primary `read` action, protected by
a policy, for the revocation bulk update. Do not expose credential resources over
JSON:API.

Why the explicit `log_out_everywhere`: in a real Postgres comparison with
AshAuthentication 4.15.0, calling the strategy's native reset directly on the
example's resource left two valid sessions (the previous one and the one the reset
produced). The same resource through `Mana.Session.PasswordReset` ended with zero
sessions and refused token replay with HTTP 422. This describes that composition,
not every configuration or version of the library; re-evaluate when those
components change.

Use `Mana.Session.RecoveryOpenApi` in the exporter and the endpoint to add these
operations to the contract. `Mana.Session.OpenApi` still serves apps that only
adopted sign-in/sign-up/session. In Flutter, `PasswordRecovery` from `ash_session`
drives the generated transport.

A consumer can use Oban to persist the request (email only, no password or JWT)
and Swoosh Local for in-memory capture in development. The 30-minute
token is generated in the worker. Failures returned or raised by the provider are
normalised before the job's history. A retry can produce another message/link:
delivery is not exactly-once; a successful reset revokes every token of the
account. Finished jobs keep the email for a while, so queues need access control and
a retention policy.

Cover the real Plug endpoint, Postgres, persisted failure/retry, purpose/expiry,
password/whitespace, concurrency, replay and revocation with the consumer's own
proofs or Moments.

## Optional email confirmation

The consumer can enable `confirmation: true` in `Mana.Session` and use
`Mana.Session.ConfirmationOpenApi`. In that contract, an accepted sign-up returns
`202 {status: "confirmation_required"}` without a Bearer; sign-in only works after
confirmation. Apps that do not opt in keep the existing sign-up. The password
strategy declares `require_confirmed_with`; Bearer identification also requires
the confirmation, including for tokens issued earlier.

`Mana.Session.Confirmation` offers `:request` (email, generic 202) and `:confirm`
(token, 204 without a session). The consumer provides the durable enqueue. Confirm
uses the AshAuthentication add-on, an account lock and transactional revocation on
the same Postgres Repo to prevent concurrent replay. The sign-up action must persist
the job together with the account; a queue failure rolls both back.

## Boundary with the Ash extensions

Hashing, token signing/verification, confirmation and revocation use the library.
The Mana transport keeps the policy of not authenticating automatically after
confirmation/reset and the transactional coordination between those operations.

`reset_request` returns `:ok` even when the Sender returns an error because delivery
is disabled. The worker calls token generation and the Sender separately so failures
go back to Oban. Secrets are never written into job arguments.

Plain Oban fits these requests: they are enqueued before looking up the identity and
have their own retry/timeout. AshOban adds resource triggers and scheduled actions;
evaluate it when that kind of processing enters the domain.

References: [AshAuthentication Confirmation](https://ash-authentication.hexdocs.pm/confirmation.html),
[LogOutEverywhere](https://ash-authentication.hexdocs.pm/AshAuthentication.AddOn.LogOutEverywhere.html)
and [AshOban](https://ash-oban.hexdocs.pm/getting-started-with-ash-oban.html).
