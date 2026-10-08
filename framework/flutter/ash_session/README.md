# Flutter session and recovery

`AshSession` takes the transport of the app's generated client, keeps the session in a
`SessionStore`, tracks identity with Signals and injects the Bearer only for the
configured origin. Rejections of the current session invalidate the identity; stale
responses never replace a newer session. It never repeats write requests.

`SessionStore.callbacks(read: ..., write: ...)` adapts another storage without
replacing the authentication flow. Moments uses that hook for a development actor's
private session; production keeps `SecureSessionStore`. A restored session always
goes through `identify`.

`SecureSessionStore.write` requires a confirming read before returning: a missing or
different value throws, and `AshSession` does not establish the session. The empty
logout value accepts the absence the Linux plugin returns. This defends against
unconfirmed writes; it does not guarantee fsync, power loss or cross-process
concurrency. Custom callbacks stay responsible for their storage's contract.

`SecureSessionStore` uses `mana_storage` over the existing provider. On the web,
unreadable records raise an error instead of looking absent, and ciphertext without
its key blocks reads/writes before the provider generates another key. The session
state becomes unavailable on failure; there is no automatic login, deletion or retry
to hide it. [Contract and limits](../mana_storage/README.md).

## Session shared across tabs

Coordination protects the local identity; it does not cancel an authentication
already performed on the server. If login A is held until B authenticates, B stays
selected, but the token issued to A remains valid until it is revoked explicitly.
Revoking tokens whose receipt was lost is not promised.

On the web, `SecureSessionStore` coordinates changes to the **session record** with Web
Locks. `AshSession` only writes if the observed value is still current: a late 401,
logout or login cannot overwrite the session another tab already replaced. The
confirming read happens inside the same lock. The lock never covers HTTP,
authentication or domain work; acquisition expires after five seconds and missing Web
Locks refuse the write, with no unprotected fallback.

Native `storage` events signal when another tab changes the record or the key. The
controller rereads the value and drops its identity when it detects a replacement; it
does not adopt the new account automatically. Adoption requires `restore` or an
explicit login, identified by the backend. A read error makes the session
unavailable. There is no polling, token broadcast, automatic login or replay.

Before attaching a Bearer, the interceptor checks the record again: an observed change
cancels the request before the transport. A response from an earlier generation does
not update the newer one; that includes a 401 with the same Bearer. This check does
not cancel effects of requests already sent nor close the window between the local
read and the send. Authorisation and revocation stay the server's responsibility.

**`guaranteed` within the coordinated web writers:** comparing/replacing the record is
atomic among those writers. **`default-safe`:** the default store turns this
coordination on; Moments private callbacks, direct calls from old clients and custom
providers are outside the property. On native, `shared` is false: no cross-process
coordination through Web Locks is promised. Updating the backend alone does not make a
tab running old code cooperate.

## Native limit

A persistence failure was observed on Linux AOT: the desktop session's keyring
reported success for a write without keeping the expected value. The same binary
passed against a fresh GNOME Keyring on an isolated D-Bus, including after SIGKILL of
the app and a service restart.

## Recovery

`password_recovery.dart` offers `PasswordRecovery`, with two injected functions:
request a link and reset. It exposes the phase, a normalised failure and the temporary
block on `429`, without keeping password, token, email or `DioException` in the
signals. There are no automatic retries. The app uses its OpenAPI client and requires
the `202`/`204` acknowledgements; the screens' content and look stay in the consumer.

The consumer owns the text controllers and the in-memory recovery capability. It must
dispose of them on exit, remove the token from the URL, clear the fields after success
and revalidate the existing session after a reset. A new link must create a new form
even when the route path does not change (with go_router, a revision counter that does
not hold the token). Clearing on exit uses
`GoRoute.onExit`, not `State.dispose`: rebuilding a widget does not mean the user left
the route.

Recovery fits two Moments, `recovery-requested` and `password-recovered`, using the
normal screens and the Ash endpoints. Inputs are private references; observations
hold only phases, destination and identifiers. The second Moment resets, signs in with
the new password and compares identity, change and revocation in Postgres. A restart
does not repeat the write.

## Sign-up with confirmation

`email_confirmation.dart` offers `EmailConfirmation` with injected `register`,
`request` and `confirm` transports. `signUp`, `requestLink` and `confirmEmail` expose
phases through Signals; sign-up success is `pending`, confirmation success is
`confirmed`. None of these operations establishes a session: signing in is a later,
explicit action. It shares with `PasswordRecovery` the admission of one operation at a
time, a bounded cooldown on 429 and safe errors, with no automatic retries or storage
of sensitive parameters.

The consumer keeps the link in memory, removes the token from the route and drops it on
exit. Tokens and passwords are not part of the restorable Moments projection. Opening a
confirmation route only presents the action: consuming it needs an explicit gesture.
