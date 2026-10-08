# Mana storage

`ManaSecureStorage` delegates encryption and platform persistence to
`flutter_secure_storage`. It adds explicit read failures for web data that the
installed provider can otherwise interpret as absent. Used by `ash_session` and
by apps' pending-creation stores. It does not replace the provider or add a
retry queue, cryptography, fallback persistence or automatic repair.

## Boundary

The web guard observes the storage selected by `WebOptions.useSessionStorage`
and the namespace selected by `WebOptions.publicKey`. It matches the on-disk
browser format of `flutter_secure_storage_web` 2.1.1, pinned by the consumer lock.
Requalify that boundary when upgrading the provider or its storage format.

- In a healthy namespace, an absent key returns null. An empty namespace returns an
  empty map.
- A ciphertext entry still present but omitted by decryption produces
  `SecureStorageUnavailable(unreadableRecord)`.
- Ciphertext without its encryption key is refused **before** calling the
  provider, on both reads and writes. A read cannot silently create a replacement
  key and render the original ciphertext inaccessible through this API.
- A relevant ciphertext or key change during an asynchronous read produces
  `changedDuringRead`. The caller can explicitly read again; the guard does not
  retry or decide that a concurrent deletion means a completed business action.
- Exceptions from the provider/browser continue to propagate. No error carries
  a stored value or an account identifier from this wrapper.

First-key generation is coordinated by an exclusive **Web Lock** scoped to the
origin, storage kind and provider namespace. The wrapper checks again after
acquiring the lock, then delegates the first write to the provider. A second
writer imports that same key. Existing-key writes do not acquire this lock;
the framework does not serialize ordinary writes or implement cryptography.
Acquisition is limited to five seconds (`initializationBusy`); the timer is
canceled when granted and never pretends to cancel an active provider write.
If Web Locks are unavailable, first initialization is refused explicitly
(`initializationUnavailable`). There is no unlocked fallback or automatic retry.

**`guaranteed` within cooperating wrapper calls and the provider format above:**
two first writers cannot replace each other's encryption key. The browser owns
the lock lifecycle. Direct/older provider callers, same-origin scripts deleting
the key, namespace changes and custom providers that ignore `WebOptions` are
outside this boundary. Session storage uses the same coordination for concurrent
calls in a document; separate tabs still have separate session storage.

These read checks are `guaranteed` only for calls through this wrapper, within
that format boundary and the observed storage snapshot. Direct calls to the
upstream library bypass them. The default integration is `default-safe`:
`SecureSessionStore` and `TaskAttemptStore.secure` use it automatically, while
private Moment callback stores and custom injected providers retain their own
contracts. This does not guarantee transactional writes between browser tabs, persistence
under quota/power failure or protection from same-origin scripts/XSS.

Native storage delegates unchanged. In particular, the installed Linux JSON-map
provider still has the documented concurrency limitation. The separate per-item
prototype and desktop keyring investigation are not adopted by this package.

## Qualification

A disposable Flutter web release loaded the real Mana stores and browser
provider. Before the guard, a corrupted attempt restored as an empty list and a
corrupted session read as null; removing the encryption key caused the reader to
create another key before failing.

The first-key race was reproduced in two release tabs in three rounds by adding
600 ms only to the provider's existing absent-key async window in a **private
qualification copy**. Both writes returned successfully, but reading both values
failed in every round. With the wrapper lock, both values survived in all three
rounds. The unmodified installed provider also passed three paired rounds.
This scheduling injection establishes the race, not its natural frequency.

A separate release with the unmodified provider filled actual localStorage to
`QuotaExceededError`. The real Tasks command refused before HTTP, retained the
prior attempt and session, and dispatched once only on explicit retry after
space was freed. A 503 receiver preserved both pending attempts. The same proof
exercised lock-acquisition timeout and successful explicit retry after release,
plus concurrent first writes to sessionStorage. These are local browser proofs,
not UI/backend journeys, mobile durability or cross-browser certification.

Missing/corrupt key recovery is explicit: preserve the ciphertext and let the
application present an unavailable state. This API does not discard it, re-login
or replay a mutation to hide the failure.
