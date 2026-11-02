defmodule ManaLint.Check.ExternalPostWithoutIdempotencyKey do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      clients: [~r/(^|\.)Stripe(\.|$)/],
      key: ~r/idempotency[-_]key/i
    ],
    explanations: [
      check: """
      Flags a POST sent from a configured client module (by default any module
      named `Stripe`) without an idempotency key: `Req.post`, a request built
      with `method: :post`, or a helper called with `:post` (`request(:post,
      "/v1/refunds", ...)`) whose arguments — and, for a helper of the module,
      whose body — carry no `Idempotency-Key`.

      A POST that times out may still have happened. The caller, an Oban
      retry, a supervisor restart or the user tapping again sends it again,
      and the provider performs it again: a second refund, a second charge, a
      second account. Only a key the provider remembers makes the retry safe.

      Instead, derive the key from what the request is for and send it on
      every POST of the client:

          Req.post(req, url: "/v1/refunds", form: fields,
            headers: [{"idempotency-key", "refund-" <> charge.id}])

      The key must be stable across retries of the same operation (a record
      id plus the operation, not a fresh UUID per attempt).
      """,
      params: [
        clients:
          "Modules (regexes or substrings of the name) whose POSTs must carry an idempotency key.",
        key: "How the key is spelled in a header name or option (a regex)."
      ]
    ]

  alias ManaLint.Code

  @requests ~w(request request! run run! new merge)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    clients = Params.get(params, :clients, __MODULE__)
    key = Params.get(params, :key, __MODULE__)

    for module <- source_file |> Code.ast() |> Code.modules(),
        Code.listed?(clients, module.name),
        node <- Code.module_calls(module),
        %{} = call <- [Code.call(node, module)],
        post?(call),
        not keyed?(call.args, key),
        not keyed_helper?(call, module, key),
        do: Code.issue(__MODULE__, issue_meta, node, message(call))
  end

  defp post?(%{fun: fun}) when fun in [:post, :post!], do: true
  defp post?(%{module: "Req", fun: fun, args: args}) when fun in @requests, do: method_post?(args)
  defp post?(%{args: args}), do: :post in args

  defp method_post?(args), do: args |> Code.nodes() |> Enum.any?(&match?({:method, :post}, &1))

  defp keyed?(ast, key) do
    ast
    |> Code.nodes()
    |> Enum.any?(fn
      text when is_binary(text) ->
        Regex.match?(key, text)

      atom when is_atom(atom) and atom not in [nil, true, false] ->
        Regex.match?(key, to_string(atom))

      _ ->
        false
    end)
  end

  # A helper that sends the key, called with every argument (an omitted
  # default, such as `key \\ nil`, sends none).
  defp keyed_helper?(%{module: nil, fun: fun, args: args}, module, key) do
    module
    |> Code.clauses(fun)
    |> Enum.any?(&(length(&1.args) == length(args) and keyed?(&1.body, key)))
  end

  defp keyed_helper?(_, _, _), do: false

  defp message(call),
    do:
      "`#{Code.name(call)}` sends a POST without an idempotency key: a retry repeats it at the provider. " <>
        "Send a key derived from the operation (`refund-<charge id>`), the same on every retry."
end
