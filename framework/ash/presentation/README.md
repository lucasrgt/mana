# Presentation declared in Elixir, compiled to Flutter

First slice: forms for create/update actions with string inputs and integers with
explicit limits. The `Mana.Presentation.Extension` belongs to the Ash resource. The
declaration is the source of truth; the generator keeps a Dart file of its own,
without editing the app's code. There is no UI JSON interpretation and no Elixir
running on the device.

```elixir
forms do
  form :create_task do
    action(:create)
    transport(:json_api)
    submit("Create task")
    submit_key("task-create")
    failure("Could not confirm the creation. Check the list.")
    input :title do
      label("New task")
      key("task-title")
      invalid("Enter a title with 1 to 120 characters.")
    end
  end
end
```

The example uses a `title` accepted by the action, public, required, a string, with
`constraints: [min_length: 1, max_length: 120, length_count: :codepoints]`. Those
constraints come from the Ash type. Password/session values, data defaults and
private fields are not exported. Private arguments are refused too. The compiler
refuses unsupported types instead of inventing a visual control for them.

An `:integer` attribute/argument with `constraints: [min: 1, max: 480]` produces a
Dart `int` input, a numeric keyboard and range validation. The input must be a
whole decimal number: fractions, hexadecimal, exponents and text are never
converted silently. Surrounding whitespace and a decimal sign are accepted. A
nullable field accepts empty as null; invalid text stays invalid. Both limits must
lie between −9,007,199,254,740,991 and 9,007,199,254,740,991 for exact parity between
web and native. Integers without limits or outside that range need their own
callback/control.

```sh
framework/cli/mana forms generate \
  --server <server> --resource MyApp.Task \
  --api-client <app>/packages/my_app_api \
  --output <app>/lib/generated/task_forms.dart
```

`--check` compares without rewriting. The host uses the Dart SDK to format the code
emitted from Elixir. The `.dart.mana.json` file records the contract and the Dart
hash; both are versionable generated sources. Editing the generated Dart by hand
makes regeneration refuse to overwrite it. Do not delete the metadata to get around
that: move the customisation to the consumer and restore the generator's known
output. An interrupted publication may leave `.lock`/`.tmp` files; inspect the
process and the files before recovering them. There is no force option.

```dart
CreateTaskForm(
  titleController: draft,
  busy: model.busy,
  onSubmit: model.create,
)
```

The output includes a typed Dart input, Material controls, presence/length
validation with the declared unit, blocking resubmission during the operation, a
safe error and clearing after confirmation. A callback that returns false or throws
neither clears the draft nor is repeated automatically. Clearing does not erase text
changed during the operation. Controllers the app provides are not disposed by the
form; internal ones are. Sensitive inputs hide text and use no autocorrect or
suggestions. With `transport(:json_api)`, `CreateTaskAction` receives the SDK's
`TaskApi` and builds the typed request from the Ash action/route and the contract
recorded in that SDK. The receipt requires status, identity and resource type;
updates also check the requested id. The authenticated transport comes from the
app. There is no retry and no parallel HTTP client. Without `transport`, the
callback mode stays available for other transports.

### Creation identity

`create_identity(:id)` is opt-in for JSON:API creates that accept a public, writable
UUID primary key. The compiler refuses update/upsert, composite keys, arguments that
shadow the identity and private/unaccepted fields. The ID never becomes a visual
control. The OpenAPI contract must expose the matching UUID attribute; the Dart
action then requires:

```dart
await CreateTaskAction(api)(input, creationId: attemptId);
```

The caller generates a UUID v4 **once per attempt**, stores it before sending and
reuses it while the result is uncertain. The generator validates its format, sends
the attribute through the SDK and requires the same ID in the 201 receipt. It never
generates another ID, retries or resolves conflicts on its own. Persisting the
attempt (for example, storing the intent before HTTP in `flutter_secure_storage`,
per API/user/ID) is the consumer's responsibility; it is not an outbox or writer
coordination offered by the generator.

Uniqueness belongs to the database's primary key; the DSL alone does not guarantee
it. The domain must review changes that replace the ID, deletes and external
effects. Knowing the ID does not authorise access to the record. A conflict is a
normal Ash error; the record is not returned through an upsert without read
policies. Older clients that omit the optional attribute do not get this attempt
protection.

`titleBuilder` receives the context and the default TextFormField: it can wrap or
replace it. When replacing it, keep the controller, validator, enabled state and key
to preserve the interaction contract. Validation is checked again before the
callback, even when the builder swaps the control. `CreateTaskCopy` lets the app
supply its own localised texts, errors included, without editing the generated file.
Theme and outer layout are ordinary Flutter.

A draft can stay tied to Moments through the controller, so the same keys and a
Moment's criteria verify the generated UI against Postgres. The local supervisor regenerates forms and exports the Moments catalog
again when it compiles backend changes, before refreshing Flutter.

## Current limits

Syncing the value of unfocused fields with the web accessibility DOM has a defect
also reproduced in plain Flutter on the installed SDK. Clearing or replacing a
controller updates the visuals but may leave the old accessible value until the
field receives focus. See the
[reproduction without Mana](../../flutter/tool/repros/off_focus_value/README.md).
Moments checks do not certify that browser layer nor replace a screen-reader audit.

This is not yet a complete screen language. Routes, queries, pagination, forms with
booleans, dates, enums and other types, screen composition and complete Moments
bindings are next slices. Custom validations, regexes and cross-field rules/Ash
policies stay authoritative on the server; the compiler only derives presence,
basic string constraints and integer limits, and does not translate arbitrary
Elixir into Dart. Input accepted locally may still be refused by the server. The
compiler does not generate business criteria to prove itself.

Verify the real flow with the Moment that submits the form (`moments run <name>`).

## Binding to the generated client

The emitter resolves the Ash route's operation, crosses method, relative path,
required fields, type and receipt with the SDK's `.mana/contract.json`, and uses the
names of the dart-dio generator pinned by Mana. The candidate output is analysed
against the package the consumer actually resolves, before publication. A different
package, an incompatible contract or unsupported naming refuses generation without
replacing the previous Dart. Regenerate the SDK first when the API changes.

Analysis evidence is incremental: signature, constraints/types, SDK code, package
configuration, Dart version and generator sources go into the hash. Label/copy/key
changes reuse the previous analysis; their literals are escaped by the emitter and
the update still goes through the Flutter compiler. The Dart is not rewritten when
only metadata changes.

This first transport supports a creating POST and a PATCH with a single `id`
parameter, string/integer inputs in `attributes` and a JSON:API resource receipt.
Upsert, relationship arguments, additional required parameters and optional update
inputs need an explicit callback. Absent and null are not interchangeable: clearing a
nullable field is not promised while the SDK does not represent them separately.
Lists/pagination, server field errors and multi-action flows are not generated yet.
The action can succeed while the re-read fails; the consumer keeps that distinction
so it never suggests repeating a write already confirmed.
