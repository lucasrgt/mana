# Ash ↔ Dart contracts

Ash keeps declaring resources/actions and exporting OpenAPI. Mana uses OpenAPI
Generator for Dart and [oasdiff](https://github.com/oasdiff/oasdiff) to compare the
declared HTTP surface. The normal path is still: edit the slice, export/generate and
run the affected Moments. There is no new hook or global gate.

## Install and compare

```sh
framework/cli/mana contracts install
framework/cli/mana contracts compare \
  --base path/to/contract-in-use.json \
  --candidate path/to/new-contract.json --json
```

The installer uses a version and file/binary hashes pinned in `toolchain.json` (the
generator jar comes from Maven Central, no npm), in the private cache
`~/.cache/mana/contracts`. The generator runs on a pinned Java runtime the installer
fetches too (Eclipse Temurin JRE from Adoptium's releases, checked against the
archive's hash and then the digest of every extracted file), so the machine needs no
Java; a `java` on the PATH is never used. The three downloads run at once. Pinned
platforms: Linux x64 and arm64, macOS arm64 and x64. Another platform requires adding
and verifying its official artifacts; there is no fallback to an arbitrary version
installed on the PATH. Each use checks the installed bytes again (the runtime's whole
tree, about a second) and asks for `mana contracts install` when they are missing or
changed; `mana doctor` reports the same in a project with a generated client. Later
comparisons are local: no account, upload, remote service, `--open` or external
references. The export must be a complete OpenAPI 3.0 JSON.

The report distinguishes `compatible`, `review`, `breaking` and `unavailable`. Exits: 0
compatible, 1 findings to handle, 2 comparison unavailable. A warning is not implicit
success. Rule IDs, methods, paths and operationIds locate the problem; hashes tie the
exact bytes of both contracts. The tool compares private copies of those bytes so the
inputs cannot change during the analysis.

## Client with recorded provenance

`mana client generate` writes into the generated package:

- `.mana/contract.json`: the contract that actually generated this client;
- `.mana/client.json`: the contract hash and the pinned generator's identity/hash.

That is persistent provenance of the code, not disposable proof. Do not edit those files
by hand. Reports live in `.proofs/`.

Before replacing an existing client, generation compares the candidate with its
provenance. Breaks/warnings keep the previous package and leave a report. An
intentional migration can use `--accept-breaking`, after handling the clients still in
use. The flag does not skip Dart compilation/analysis.

For a legacy client without that provenance, `--establish-baseline` is a one-time
explicit adoption: it regenerates and records the contract. It claims no compatibility
with a provenance that was never recorded. Packages without the OpenAPI Generator mark
are not replaced.

Generation happens in a temporary folder, validates the OpenAPI, compiles serializers
and analyses the package. `--consumer <app>` also analyses the real consumer's `lib`
at the package's final path. If it fails, the previous package is restored. The report
records the failing stage and does not declare the generation complete. That analysis
catches, for example, an operationId change that keeps the HTTP surface but renames the
Dart method. The app must already have its dependencies resolved.

The pinned generator's dart-dio output has two faults Mana corrects before compiling,
on the parsed Dart (`package:analyzer`), each edit touching only the characters it
changes: an import repeated word for word (an operation answering a free-form object
imports `json_object` twice) is dropped, and a top-level array response declared
`BuiltList<T>` but read as `BuiltSet` is read as the list it declares, with its
`ListBuilder<T>` registered in `serializers.dart` (in file-name order, so the output
does not depend on directory listing order). A read of another shape is left as
generated; serializers without the expected cascade fail the generation. Custom
templates were rejected: they would fork whole generator templates for two edits.
`cli/test/client_test.dart` checks each edit and the bytes of a fixture client
(`cli/test/fixtures/client`).

## Evolution policy

The direction is **the existing client against the server's candidate declaration**.
Accepting more input values usually keeps clients working; starting to return a new enum
value can break an old decoder. The comparator understands those directions. Requiring
a new field, removing an endpoint and dropping response guarantees need a migration.

In a production upgrade, the base must be the contract of the clients still supported,
kept in the release's artifact/tag. The last client generated in development does not
automatically represent the mobile apps already distributed. Keep old endpoints during
the migration, or create an explicit new version. Changing `info.version` alone does not
make a break compatible. A hash identifies provenance; it is not a rule for rejecting
clients at runtime when the API gains a compatible field.

The comparator does not prove the server implements the declaration, authorises the
right actor or keeps business semantics. Moments keep exercising the UI, real actions
and persisted postconditions. HTTP compatibility, Dart compilation and an observed
journey are distinct evidence.

In practice, a compatible HTTP rename passed the generator and then failed in an
isolated real consumer, and a new required input was refused before the package was
swapped; in both cases the previous package was restored byte for byte.
