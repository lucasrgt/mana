defmodule Mana.Lock do
  @moduledoc """
  Holds one record for the rest of the transaction.

  `record(repo, key)` takes a Postgres transaction-level advisory lock on
  `key` (by convention `"<entity type>:<id>"`). A second transaction asking
  for the same key waits until the first commits or rolls back. The key is
  hashed to 64 bits, so unrelated records practically never share a lock.

  Call it inside a transaction (an action's `before_action` hook); outside
  one the lock is released at once.
  """

  @doc "Locks `key` on `repo` until the surrounding transaction ends."
  @spec record(module(), String.t()) :: :ok
  def record(repo, key) when is_atom(repo) and is_binary(key) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end
end
