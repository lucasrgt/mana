# __name__

An app built with [Mana](https://github.com/lucasrgt/mana): an Ash backend in
`backend/`, a Flutter app in `app/` with its generated API client in
`packages/api/`, and Mana itself as a git submodule in `mana/`.

It starts as a list of notes, enough to show every layer working: the `Note`
resource with a `complete` verb the app only offers when the server does, and
two Moments, an empty list and a note being added, checked on the screen and
in the database.

## Requirements

Docker (the backend and its database run in containers), the Flutter SDK and
git. Nothing else has to be installed on the machine.

## Every day

```sh
git submodule update --init            # after cloning

# Moments: named situations of the running app
mana/framework/moments/moments suite --headless --project app   # every Moment, headless
mana/framework/moments/moments open note-added --project app    # one, in the app
mana/framework/moments/moments sync --project app               # after changing Moments in the backend

# The backend against a Moments sandbox (started by `moments up`)
export MANA_MOMENTS_INSTANCE=$PWD/app/moments/.backend/instance.json
mana/framework/cli/mana lab test       # ExUnit
mana/framework/cli/mana lab mix ash.codegen <name>   # a migration after changing resources

# The API client, after changing the backend's resources or routes
mana/framework/cli/mana mix backend contracts.export __Name__.Notes /api ../contract/api.json __Name__Web.OpenApi
mana/framework/cli/mana client generate --input contract/api.json --output packages/api --name __name___api

# What Mana already offers, and where each file belongs
mana/framework/cli/mana capabilities <topic>
mana/framework/cli/mana doctor
```

## Where things go

| Path | What it is |
| --- | --- |
| `backend/lib/__name__/notes.ex` | the domain and its resource; replace it with yours |
| `backend/lib/__name__/moments.ex` | the Moments: backend recipes and what each situation must show |
| `backend/lib/__name___web/` | endpoint, router (health, recipes, JSON:API), CORS, contract |
| `app/lib/app.dart` | the app; the Moments engine drives it through `MomentHost` |
| `app/moments/backend.json` | how Moments start the backend (`mana lab`) and the app |
| `packages/api/` | the generated Dart client; never edit by hand |
| `mana/` | the framework, pinned to a commit; update it with `git -C mana checkout <commit>` |
