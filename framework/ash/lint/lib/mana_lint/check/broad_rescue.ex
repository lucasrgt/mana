defmodule ManaLint.Check.BroadRescue do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [
      allowed_paths: [~r"(^|/)test/"],
      reporters: [
        "Logger",
        ~r/(^|\.)Sentry(\.|$)/,
        ":telemetry",
        "IO.warn",
        ~r/\.report\w*!?$/
      ]
    ],
    explanations: [
      check: """
      Flags `rescue _ ->` (and `catch _, _ ->`) whose body neither re-raises
      nor reports: no `raise`/`reraise`/`throw`/`exit`, no `Logger`, error
      reporter or telemetry call, directly or in a function of the module it
      calls.

      Rescuing everything and returning a default turns every failure into a
      plausible answer: a policy that crashes reads as "not allowed", a repair
      that crashes reads as "nothing to repair", a typo in a query reads as
      "no rows". Nobody hears about it, so nobody fixes it, and the default
      quietly becomes behaviour.

      Instead, rescue what you expect and let the rest crash (a supervisor or
      the job's retry handles it):

          rescue
            e in [Ash.Error.Forbidden, Ash.Error.Invalid] -> {:error, e}

      If everything must be caught (an isolation boundary), report what was
      caught before returning: `Logger.error(Exception.format(:error, e,
      __STACKTRACE__))`, the app's error reporter or a telemetry event.
      """,
      params: [
        allowed_paths:
          "Paths (regexes or substrings) where catching everything is fine (tests asserting a failure).",
        reporters:
          "Calls that report an error (a module, `\"Mod.fun\"`, `{Mod, :fun}` or a regex on `\"Mod.fun\"`); a local function is matched as `\"ThisModule.fun\"`."
      ]
    ]

  alias ManaLint.Code

  @raises [:raise, :reraise, :throw, :exit]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Code.listed?(Params.get(params, :allowed_paths, __MODULE__), source_file.filename),
      do: [],
      else: issues(source_file, params)
  end

  defp issues(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    reporters = Params.get(params, :reporters, __MODULE__)

    for module <- source_file |> Code.ast() |> Code.modules(),
        node <- Code.module_nodes(module),
        {kind, clauses} <- handlers(node),
        {:->, _, [patterns, body]} <- clauses,
        at = broad(kind, patterns),
        at != nil,
        not reports?(body, module, reporters, 1),
        do: Code.issue(__MODULE__, issue_meta, at, message(kind))
  end

  defp handlers(node) when is_list(node) do
    if Keyword.keyword?(node),
      do:
        for(
          {kind, clauses} when kind in [:rescue, :catch] and is_list(clauses) <- node,
          do: {kind, clauses}
        ),
      else: []
  end

  defp handlers(_), do: []

  defp broad(:rescue, [pattern]), do: if(discarded?(pattern), do: pattern)

  defp broad(:catch, [_ | _] = patterns),
    do: if(Enum.all?(patterns, &discarded?/1), do: hd(patterns))

  defp broad(_, _), do: nil

  defp discarded?({name, _, context}) when is_atom(name) and is_atom(context),
    do: name |> to_string() |> String.starts_with?("_")

  defp discarded?(_), do: false

  defp reports?(body, module, reporters, depth) do
    body
    |> Code.nodes()
    |> Enum.any?(fn node ->
      case Code.call(node, module) do
        %{module: nil, fun: fun} when fun in @raises -> true
        %{module: nil, fun: fun} -> local_reports?(module, fun, reporters, depth)
        %{module: mod, fun: fun} -> Code.matches?(reporters, mod, fun)
        nil -> false
      end
    end)
  end

  defp local_reports?(module, fun, reporters, depth) do
    Code.matches?(reporters, module.name, fun) or
      (depth > 0 and
         Enum.any?(Code.clauses(module, fun), &reports?(&1.body, module, reporters, depth - 1)))
  end

  defp message(kind),
    do:
      "`#{kind}` catches everything and neither re-raises nor reports: failures read as a normal answer. " <>
        "Rescue the errors you expect, or report what was caught."
end
