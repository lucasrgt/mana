# Editable fullstack slice

This scaffold offers **one specific starting point**: a collection owned by an actor,
reads limited to 100 records and an action that sets a boolean. It is not a
universal UI language and does not turn every domain into CRUD. The result uses Ash,
Dart, Signals, result_command and go_router directly. The app adapts behaviour,
pagination, presentation, errors and translation as it needs. The generator takes no
part in the runtime.

## Using it in a consumer

From the repository root, with the Flutter SDK on the PATH:

```sh
node framework/scaffold/slice.mjs bookmarks \
  --record Bookmark --action archive --state archived \
  --project <project>
```

Repeating it for an existing slice is refused. For a new feature, choose other names. Collection, action and state
use snake_case; the record uses PascalCase without ambiguous acronyms. These names
enter the public contract and should describe the domain.

The command creates:

- `server/lib/features/<collection>.ex`: resource, policy, domain and Moments;
- `server/priv/repo/migrations/<timestamp>_create_<collection>.exs`: migration;
- `app/lib/features/<collection>.dart`: typed adapter, model and screen;
- `app/moments/features/<collection>.mjs`: local preparation and observation.

The `client_roots` declaration points to the feature's library and enables selection
by static imports; it also feeds the refresh inventory. Dependencies injected from
outside the slice must join that declaration when adopted.

These files become the app's code. **Edit them normally**; a second slice does not
regenerate them. Opening a journey Moment prepares its entry; only `run` performs the
gestures. `refresh --check` does not repeat preparation or gestures. The fixture has a
stable UUID, belongs to the declared local actor and can only be reset when owner and
title match the synthetic identity. No HTTP fixture/reset route is installed. `inbox`
observes without writing; `journey` prepares explicitly and requires backend and UI
postconditions.

The generator maintains only three indexes:

- `server/config/mana_slices.exs`: Ash domains;
- `app/lib/generated/mana_routes.dart`: go_router routes;
- `app/moments/slices.mjs`: exportable domains and recipes.

`.mana/slices.json` records slices and the hashes of those indexes; it should follow
the code in Git. Manual changes to the indexes make the next generation stop before
creating files. Reconcile the change instead of deleting the record. `mana.toml`
configures paths, module, Dart package, database, Moments base and synthetic actor. It
holds no credentials.

## First integration in another app

An explicit, one-time integration; the scaffold never rewrites entry points:

1. Provide Ash/Postgres/JSON:API + the local `moments` and `contracts` dependencies;
   in Flutter, live_ui, Dio, Signals, result_command, result_dart and go_router.
   Configure the Repo, real session and the local Moments base in the app.
2. Create `mana.toml` with your existing
   `baseDomains`. `fixtureActorId` must match the authenticated actor **of the local
   environment**.
3. After the first slice, import `mana_slices.exs` in the Elixir config and use
   `Application.compile_env(:your_app, :ash_domains)` in AshJsonApi.Router.
4. Add `...manaSliceRoutes(dio)` to the GoRouter. The authenticated Dio belongs to
   the app; the slice neither closes the shared transport nor creates another session.
5. In the sandbox configuration, merge `generatedRecipes({headers})` with the app's
   recipes and use `generatedDomains` in `moments.export`. The app supplies the
   headers; tokens never enter the generated files.
6. Export the contract, generate the typed client and add its local dependency to the
   pubspec. Run the migrations before starting the service.

Exporting **without starting the API or the database**:

```sh
framework/cli/mana mix <server> contracts.export MyApp.Domain /api ../app/contract/MyApp.json
framework/cli/mana client generate \
  --input <app>/contract/MyApp.json \
  --output <app>/packages/my_app_api \
  --name my_app_api \
  --consumer <app> \
  --report <app>/moments/.proofs/scaffold/client-generation.json
framework/moments/moments sync --project <app>
```

The generator's version and checksum are pinned in the contracts toolchain
(`framework/cli/mana contracts install`). On the first generation, before the package
exists and before `flutter pub get`, omit `--consumer`; then resolve dependencies and
analyse the app. On later ones, the consumer analysis protects the swap of the
generated client.

The scaffold runs no migrations, starts no services and never touches production.
Files are published atomically one by one; a normal exception rolls the generation
back. An abrupt interruption leaves `.mana/scaffold.lock`: inspect the listed files
before removing the marker and resuming. There is no durable transaction across all
files and no protection against concurrent edits outside the generator.

## Proof

The declared journey is the fullstack proof: Flutter → generated client → Ash →
PostgreSQL, with UI and backend postconditions. Also exercise the Ash policy (anonymous
and other-actor reads/writes denied) and compare the paths and schemas exported offline
with the running API. The scaffold does not impose unit + integration + E2E per slice;
add focused checks where there is concrete risk.
