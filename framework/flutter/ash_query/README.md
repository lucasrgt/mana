# Ash read pages in Flutter

`OffsetPage<T>` interprets the native `meta.page` metadata of an Ash read with offset
pagination and counting. It implements no transport, authentication, cache, state
management or second query DSL.

```elixir
read :list do
  prepare build(sort: [:id])
  pagination offset?: true, default_limit: 100,
    max_page_size: 100, countable: :by_default
end
```

The client generated from OpenAPI receives typed `page` and `filter` parameters. After
validating the status and the presence of the payload, the consumer converts the
resources and hands `response.data.meta['page'].value` to `OffsetPage.fromAsh`, along
with `requestedOffset` and `requestedLimit`. `items` is immutable; `total`, `hasNext`
and `hasPrevious` drive navigation.

The parser refuses missing metadata, an offset/limit different from the requested ones
and an incomplete number of records. That avoids reading a truncated response as a
valid page. An inconsistent concurrent count is refused too; the consumer should offer
a re-read, without repeating mutations. Offset pagination gives no snapshot across
requests: concurrent inserts/deletes can shift records. Keyset, queries without counts
and offline cache are not capabilities of this first adapter.

With Signals in charge of state, each list request has a version;
a late response never replaces the most recent query. Page and filter are restorable by
Moments; records and total are observed and re-read from Ash. The observer receives
only a copy of the screen's projection to select offset/filter, validates those
parameters and compares the API with Postgres. No data received from the UI is used as
the expected database result.

Focused check of the page contract:

```sh
dart run framework/flutter/ash_query/tool/prove_offset_page.dart
```

Declare the fullstack journey as a Moment that pages through real records.
