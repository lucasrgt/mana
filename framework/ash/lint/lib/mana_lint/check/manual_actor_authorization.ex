defmodule ManaLint.Check.ManualActorAuthorization do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Flags a read with `authorize?: false` (`Ash.get`, `read`, `read_one`) in
      an action implementation (`run/3`), a change (`change/3`) or a
      validation (`validate/3`) — or a function of the module they call —
      whose result is then compared with `actor.id` (`booking.traveler_id ==
      actor.id`, a `when id == actor.id` guard, `actor.id in [...]`).

      That is authorization written by hand: the policy is switched off, then
      re-implemented with an `==`. It is invisible to `Ash.can?`, so a verb is
      offered to someone it refuses (or the other way round), it does not
      reach the contract or the generated client, it differs between the
      paths that read the same record, and the next edit can drop the
      comparison without any test noticing.

      Instead, read as the actor (`Ash.get(Booking, id, actor: actor)`) under
      a read policy — `authorize_if expr(traveler_id == ^actor(:id))`, a
      relates-to-actor check or a `FilterCheck` — and keep the action's own
      checks in its policies or in a verb's `when`. Use `authorize?: false`
      only where the read is not the user's boundary, and do not compare it
      with the actor.
      """
    ]

  alias ManaLint.Code

  @callbacks %{
    "Ash.Resource.Actions.Implementation" => :run,
    "Ash.Resource.Change" => :change,
    "Ash.Resource.Validation" => :validate
  }
  @reads ~w(get get! read read! read_one read_one!)a
  @comparisons [:==, :!=, :===, :!==, :in]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    for module <- source_file |> Code.ast() |> Code.modules(),
        callback <- callbacks(module),
        clause <- reachable(module, Code.clauses(module, callback)),
        {read, vars} <- unauthorized_reads(clause.body, module),
        compares_actor?(clause.body, vars),
        uniq: true,
        do: Code.issue(__MODULE__, issue_meta, read, message(Code.call(read, module)))
  end

  # Each unauthorized read with the variables its result is bound to.
  defp unauthorized_reads(body, module) do
    for node <- Code.nodes(body),
        {patterns, rhs} <- bindings(node),
        read <- Code.find(rhs, &unauthorized_read?(&1, module)),
        do: {read, Enum.flat_map(patterns, &Code.pattern_vars/1)}
  end

  defp bindings({op, _, [pattern, rhs]}) when op in [:=, :<-], do: [{[pattern], rhs}]

  defp bindings({:case, _, [subject, [do: clauses]]}) when is_list(clauses),
    do: [{for({:->, _, [[pattern], _]} <- clauses, do: unguarded(pattern)), subject}]

  defp bindings(_), do: []

  defp unguarded({:when, _, [pattern, _guard]}), do: pattern
  defp unguarded(pattern), do: pattern

  defp callbacks(module),
    do: for({used, callback} <- @callbacks, used in module.uses, do: callback)

  defp reachable(module, clauses, seen \\ MapSet.new()) do
    names =
      for clause <- clauses,
          node <- Code.nodes(clause.body),
          %{module: nil, fun: fun} <- [Code.call(node, module)],
          not MapSet.member?(seen, fun),
          Code.clauses(module, fun) != [],
          uniq: true,
          do: fun

    seen = MapSet.union(seen, MapSet.new(Enum.map(clauses, & &1.name)))

    case Enum.reject(names, &MapSet.member?(seen, &1)) do
      [] -> clauses
      new -> clauses ++ reachable(module, Enum.flat_map(new, &Code.clauses(module, &1)), seen)
    end
  end

  defp unauthorized_read?(node, module) do
    case Code.call(node, module) do
      %{module: "Ash", fun: fun, args: args} when fun in @reads ->
        Enum.any?(args, &(Code.option(&1, :authorize?) == false))

      _ ->
        false
    end
  end

  defp compares_actor?(body, vars) do
    body
    |> Code.nodes()
    |> Enum.any?(fn
      {op, _, [left, right]} when op in @comparisons ->
        (actor_id?(left) and Code.mentions?(right, vars)) or
          (actor_id?(right) and Code.mentions?(left, vars))

      _ ->
        false
    end)
  end

  defp actor_id?({{:., _, [actor, :id]}, _, []}), do: actor?(actor)
  defp actor_id?(_), do: false

  defp actor?({:actor, _, context}) when is_atom(context), do: true
  defp actor?({{:., _, [_, :actor]}, _, []}), do: true
  defp actor?(_), do: false

  defp message(call),
    do:
      "`#{Code.name(call)}` with `authorize?: false`, then compared with `actor.id`: authorization by hand, " <>
        "invisible to `Ash.can?`. Read as the actor under a read policy."
end
