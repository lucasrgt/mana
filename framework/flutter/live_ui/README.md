# live_ui — the Flutter side of Moments

The active path is Dart + [Moments](../../moments/README.md): recompile/refresh
and resume the declared situation. The package keeps the `live_ui` name for
compatibility; it also holds the typed property editor described at the end.

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

## Property editor (Live UI)

Edits presentation properties on an already compiled Flutter screen without
restarting the app. The package is consumed through `path:`; it needs no
publication and no Flutter fork.

```sh
framework/moments/moments live run
```

Open the screen. The initial compilation still happens. Once the screen is open,
run in another terminal (or from the agent):

```sh
framework/moments/moments live patch '{"signup.title.en":"Your next trip","signup.title.role":"h2","signup.title.tone":"secondary","signup.title.gap":"xxl","signup.submit.en":"Let us start","signup.submit.gap":"lg","signup.submit.corner":"md"}' --wait
framework/moments/moments live status
framework/moments/moments live reset --wait
```

`reset` returns to the original properties without clearing the form. A `null`
value in a patch removes only that property. `status` lists the schema, revision
and frame confirmations; it never exposes form fields. `--wait` fails if no
client confirms within 8 s, but reports that the file was already saved.

`--project /path/to/app` selects another integrated project. `WEB_PORT` and
`LIVE_UI_PORT` change the default ports 5184 and 18740. `serve` starts only the
bridge. Stop with Ctrl+C. If a crash leaves session files behind, confirm the
process recorded in `live-ui/.runtime.json` has ended before removing that file
and `live-ui/.defines.json` and starting another session.

### Files and limits

- `live-ui/schema.json`: editable properties and accepted values; references to
  existing tokens, no executable code.
- `live-ui/overrides.json`: persisted state, versionable. It only shows when Live
  UI is enabled.
- `.runtime.json` and `.defines.json`: local ignored files, mode 0600, with an
  ephemeral token. They must not go into Git.

The bridge atomically replaces the JSON before publishing a revision. Flutter
receives the revision through long polling, updates an `InheritedNotifier` and
confirms when a frame ends. The same state tree, controllers and focus stay
mounted. Changes made directly to the JSON are read when the bridge starts;
during a session, use `patch` to persist and notify together.

The connection requires debug + `MANA_LIVE_UI=true`. Profile/release use the
values in the code, including incorporated adjustments. The bridge listens only on
127.0.0.1 and requires a token; it accepts visual properties only. There is no code
evaluation, command execution or credential collection. The design system takes
ordinary optional parameters, without depending on this package.

This does not turn any Dart edit into an instant edit. New widgets, actions,
dependencies or exposed properties need compilation/hot reload. Promotion to code
is explicit: `incorporate` prepares the review and `incorporate --write` writes
the values into Dart/ARB.

On a local web build, one batch of seven properties was confirmed 38.1 ms after the
patch, and ten following batches had a median of 33.3 ms (min 26.5, max 46.5 ms;
[samples](measurements.json)). The metric starts after the patch is read and
validated, before persistence, and ends when the bridge receives Flutter's
`endOfFrame` confirmation. It excludes the agent's decision, tool calls and the
physical scanout; it is not a total perceived-latency benchmark.

### Incorporating into the app

```sh
framework/moments/moments live incorporate
framework/moments/moments live incorporate --write
```

The first command shows property, file, current and proposed value, without
changing sources, and saves an ignored local plan. The second recomputes the plan
and refuses to write if sources, schema, mapping or preview changed since the
review. It requires no commit, publication or external approval.

`live-ui/targets.json` maps properties to ARB keys or enum constants in existing
files inside `lib/`. Text goes to the edited language's ARB; other languages'
translations stay intact. Labels with ICU placeholders need an explicit
localisation edit. Properties without a declared target are never incorporated
silently.

Visual adjustments live in a presentation file as ordinary Dart constants the View
uses as defaults. That file neither imports Live UI nor reads JSON at runtime. It
is not an arbitrary Dart rewriter: the adapter recognises explicitly mapped
`const name = Type.value;` initialisers.

After writing, run `flutter gen-l10n` in the client and use the normal
recompile/reload flow. Incorporation keeps the preview, since the open app still
contains the previously compiled defaults. After recompiling, `reset --wait` can
clear the preview. Reset does not undo incorporation; for that, review/revert only
the matching hunks in Git.

Writing preserves unrelated content. Write errors try to restore files already
written, without overwriting a new concurrent change. There is no transaction
across files that survives an abrupt stop; after an interruption, review the diff
before repeating. Leftover temporary files block a repetition instead of being
overwritten.

## Focused verification

```sh
(cd framework/moments && dart test)
(cd framework/flutter/live_ui && flutter test)
```

The bridge test uses real HTTP and a temporary disk: authentication, origin,
atomic batch validation, revision delivery, confirmation, reset and persistence
across sessions.
