Some deletions of stored files happen inside a database transaction, before
it commits: when the transaction rolls back, the rows come back but the
stored objects are already gone.

- When an export expires (`expire_export` on a data request), the request
  must forget its file at once, and the stored file must be deleted only
  once that commits.
- Deleting a property whose photos are deleted with it, and fulfilling a
  person's erasure request, must keep the stored objects (and thumbnails)
  until the deletion commits; a rolled-back one keeps rows and objects.

Delete stored objects through an Oban job, `Hostpoint.Files.DeleteStored`,
in the `:maintenance` queue, enqueued inside the transaction that drops the
rows, with args `%{keys: [...]}` (a file's storage key, then its thumbnail
key). Deleting a missing object must succeed, so a retry is harmless.
