# live_ui — the Flutter side of Moments

The edit path is Dart + [Moments](../../moments/README.md): save, reload or
restart, and resume the declared situation. The package keeps the `live_ui` name
for compatibility.

## Typed drafts

`DraftField` declares the projection's fields; `MomentDraft` keeps values,
controllers, selection, the last edit focus and the scroll binding. The app waits
for its data, resolves the identity and mounts the screen/modal in
`restoreView`; then the framework applies focus and selection.
`binding.attach(context, ready: ...)` connects to `MomentScope`.

```dart
final comment = DraftField.text('comment', maxLength: 2000);
final draft = MomentDraft(
  route: '/reviews',
  fields: [comment],
  restoreView: mountReviewModal,
);
// TextField(controller: draft.textController(comment),
//           focusNode: draft.focusNode(comment))
// Dispose the draft when the last widget using its controllers goes away.
```

Available fields: editable text, a length-limited identifier, a choice and a map
of integer scores limited by range/count. `id` does not validate UUIDs,
existence or authorisation. `read`/`write` use the same declared descriptor;
`reset` clears only the given fields. Changing a map returned by `read` requires
`capture()`; snapshots copy the map. Controllers and focus capture changes.

Only declared fields enter the snapshot. The codec rejects an invalid projection
before touching controllers; the binding records the failure without confirming
restoration or overwriting the saved draft. Local text above the limit is not
truncated: the capture is refused, with the error in
`MomentController.lastError`. That does not replace form or API validation. The
keys `${key}Base`, `${key}Extent`, `focus`, `route` and `scrollOffset` make up the
existing contract. The Dart and Ash limits are still declared separately.

There is no restoration of an in-flight submission and no repetition of a network
operation.

## Session availability gate

`MomentRuntimeBlocker(reason: ..., child: ...)` connects the app's existing gate to
the Moments diagnostics. Use `MomentBlockReason.authenticationRequired` when the
requested state needs a login, `sessionUnavailable` when the app cannot verify the
session and `null` when access is available. The missing login an authentication
Moment expects is not a block.

The widget is inert outside a development `MomentScope`. It manages no
credentials, navigation or authorisation. While a block is active, the controller
refuses frame evidence and captures; clearing the reason does not confirm
restoration. See [resume blocked by the session](../../moments/README.md#resume-blocked-by-the-session).

## Controls that know their verb

In a Moments build, `MomentHost` turns on `MomentAffordances` (mana_primitives):
every mounted `VerbGate` (mana_command) records the verb it offers, as
`type.verb` or `type.verb:<recordId>`, and each screen report carries that list
as `offered`. When the list changes and the projection does not, the last
projection is reported again. The gesture driver reads a target
`verb:<type>.<verb>` with no record as any record's control, the first in tree
order; `verb:<type>.<verb>:<id>` is that record's. A gesture's
`MomentActionTrace` names its verb (from the target, or from `runVerb` as it
runs) and forwards it as `verb` with each action receipt.

## Requests in flight

`MomentActionTrace.attach(dio, api)` also counts the app's requests in flight
through that Dio (`MomentActivity.inFlight`), and `MomentController` reports
each change to the runner (`/moments/activity`: revision, client, sequence and
the count, nothing about the requests). A journey's wait reads it as progress:
while the app waits on the backend, a step's postcondition keeps waiting (see
[Journeys](../../moments/README.md#journeys)). A runner that does not know the
report answers 404 and the controller stops sending it; a lost report only
shortens the wait. It is a hint for the wait, never a criterion.

## Running actions

The Moments package offers no Command or Result engine. A slice can use
`Command1` from `result_command` and `Result` from `result_dart` directly, as
dependencies of the Flutter client, not of the Moments development runtime.

The Command owns execution state and excludes concurrent calls. A write action
can wrap the write and the list refresh, returning success even if only the
refresh failed. Rejection and an uncertain result are failures with an explicit
reason; `busy` answers a concurrent attempt without touching the operation in
progress.

Command cancellation/reset and timeout are not exposed by a write slice: those
local operations do not prove cancellation on the server. When the screen
closes, its listeners are disconnected immediately; the Command is disposed only
after its execution ends. After a timeout, a server error or "already done",
query the author's own records; only a receipt for the same record confirms the
write. An empty list or a read error keeps the result uncertain, with no second
POST.

The Moment's draft is persisted separately. An in-memory operation log does not
guarantee idempotency across restarts, tabs, clients or processes; a durable
write guarantee needs backend support (see Mana's verbs). Moments does not
depend on any state-management library and does not serialize a reactive graph.

## Focused verification

```sh
(cd framework/moments && dart test)
(cd framework/flutter/live_ui && flutter test)
```

The bridge test uses real HTTP and a temporary disk: authentication, origin and
the absence of the removed presentation endpoints.
