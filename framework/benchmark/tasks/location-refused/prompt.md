On the travelers' map, a traveler who refused the location for good is left
on the map's default area without a word, and coming back to the app does
not ask again.

Say that the location is off, with a button that opens the app's settings
on a phone, and locate again when the traveler comes back to the app. A
browser has no such settings, so on the web nothing changes.

`TravelerHomeViewModel` takes a `locationBlocked: Future<bool> Function()?`
(whether the platform's permission is denied for good), exposes
`bool get locationBlocked` after it tried to locate, and has
`void relocate()`, which asks for the position again only when it was
blocked.
