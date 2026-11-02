defmodule ManaLint.Code do
  @moduledoc false
  # Source as the checks read it: pipes rewritten as plain calls (so a call's
  # first argument is its subject wherever it was written), modules with their
  # aliases resolved, and calls named by the module they reach.

  alias Credo.SourceFile

  @fixture_paths [
    ~r"(^|/)test/",
    ~r"(^|/)priv/repo/seeds",
    ~r"(^|/)lib/[^/]+/moments(/|\.ex$)",
    ~r"(^|/)support/"
  ]

  @doc "Test, seed, Moments recipe and support paths: where fixtures are written."
  def fixture_paths, do: @fixture_paths

  def ast(%SourceFile{} = source_file), do: source_file |> SourceFile.ast() |> unpipe()

  def unpipe(ast), do: Macro.postwalk(ast, &unpipe_node/1)

  defp unpipe_node({:|>, _, [lhs, {call, meta, args}]}) when is_list(args),
    do: {call, meta, [lhs | args]}

  defp unpipe_node({:|>, _, [lhs, {name, meta, context}]})
       when is_atom(name) and is_atom(context),
       do: {name, meta, [lhs]}

  defp unpipe_node(node), do: node

  @doc """
  Every module in `ast`, nested ones included, each with its own body; code
  outside any module (a script) comes first, as a module named `""`.
  """
  def modules(ast) do
    script = %{name: "", aliases: %{}, body: ast, uses: [], attributes: %{}}
    [script | modules_in(ast, nil)]
  end

  defp modules_in(ast, parent) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [name, [{:do, body} | _]]}, acc ->
          module = module(name, body, parent)
          {nil, acc ++ [module | modules_in(body, module)]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp module(name_ast, body, parent) do
    name = module_name(name_ast, parent)
    {forms, nested} = shallow(body)

    inherited =
      Enum.reduce(nested, (parent && parent.aliases) || %{}, fn first, acc ->
        Map.put(acc, to_string(first), name <> "." <> to_string(first))
      end)

    scope = %{name: name, aliases: inherited}
    scope = %{scope | aliases: Enum.reduce(forms, inherited, &add_alias(&1, &2, scope))}

    Map.merge(scope, %{
      body: body,
      uses: for({:use, _, [used | _]} <- forms, do: resolve(used, scope)),
      attributes:
        for(
          {:@, _, [{key, _, [value]}]} <- forms,
          is_binary(value),
          into: %{},
          do: {key, value}
        )
    })
  end

  defp module_name({:__aliases__, _, parts}, nil), do: join(parts)
  defp module_name({:__aliases__, _, parts}, parent), do: parent.name <> "." <> join(parts)
  defp module_name(other, _), do: inspect(other)

  defp add_alias({:alias, _, [{:__aliases__, _, parts} = target]}, aliases, scope),
    do:
      Map.put(
        aliases,
        parts |> List.last() |> to_string(),
        resolve(target, %{scope | aliases: aliases})
      )

  defp add_alias({:alias, _, [target, [as: {:__aliases__, _, [as]}]]}, aliases, scope),
    do: Map.put(aliases, to_string(as), resolve(target, %{scope | aliases: aliases}))

  defp add_alias({:alias, _, [{{:., _, [base, :{}]}, _, children}]}, aliases, scope) do
    prefix = resolve(base, %{scope | aliases: aliases})

    Enum.reduce(children, aliases, fn
      {:__aliases__, _, parts}, acc ->
        Map.put(acc, parts |> List.last() |> to_string(), prefix <> "." <> join(parts))

      _, acc ->
        acc
    end)
  end

  defp add_alias(_, aliases, _), do: aliases

  # The module's own forms, without descending into nested modules, and the
  # first segment of each nested module's name (an alias in its parent).
  defp shallow(body) do
    {_, {nodes, nested}} =
      Macro.prewalk(body, {[], []}, fn
        {:defmodule, _, [{:__aliases__, _, [first | _]} | _]}, {nodes, nested}
        when is_atom(first) ->
          {nil, {nodes, [first | nested]}}

        {:defmodule, _, _}, acc ->
          {nil, acc}

        node, {nodes, nested} ->
          {node, {[node | nodes], nested}}
      end)

    {Enum.reverse(nodes), nested}
  end

  @doc "The module name an alias reaches from `module`."
  def resolve({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, module),
    do: Enum.join([module.name | Enum.map(rest, &to_string/1)], ".")

  def resolve({:__aliases__, _, [:"Elixir" | rest]}, _), do: join(rest)

  def resolve({:__aliases__, _, [head | rest]}, module) when is_atom(head) do
    base = Map.get((module && module.aliases) || %{}, to_string(head), to_string(head))
    Enum.join([base | Enum.map(rest, &to_string/1)], ".")
  end

  def resolve({:__MODULE__, _, _}, module), do: module.name
  def resolve(atom, _) when is_atom(atom), do: inspect(atom)
  def resolve(_, _), do: nil

  defp join(parts), do: Enum.map_join(parts, ".", &to_string/1)

  @doc "The functions a module defines: one entry per clause."
  def defs(%{body: body}), do: body |> exprs() |> Enum.flat_map(&def_clause/1)

  def exprs({:__block__, _, exprs}), do: exprs
  def exprs(nil), do: []
  def exprs(expr), do: [expr]

  defp def_clause({kind, meta, [head, body]}) when kind in [:def, :defp] and is_list(body) do
    call = head(head)
    {name, _, args} = call
    args = List.wrap(args)

    [
      %{
        kind: kind,
        name: name,
        arity: length(args),
        args: args,
        meta: meta,
        head: call,
        body: body
      }
    ]
  end

  defp def_clause(_), do: []

  defp head({:when, _, [head, _guard]}), do: head(head)
  defp head(head), do: head

  @doc "The module's code without its function heads (a head is not a call)."
  def module_calls(module) do
    heads = module |> defs() |> MapSet.new(& &1.head)
    module |> module_nodes() |> Enum.reject(&MapSet.member?(heads, &1))
  end

  @doc "Clauses of `module` named `name` (any arity)."
  def clauses(module, name), do: module |> defs() |> Enum.filter(&(&1.name == name))

  @doc """
  The call `node` makes, or nil: `%{module: "Full.Name" | nil, fun: atom, args:
  list}`. A local call has a nil module; an Erlang module is `":name"`.
  """
  def call({{:., _, [{:__aliases__, _, _} = target, fun]}, _, args}, module)
      when is_atom(fun) and is_list(args),
      do: %{module: resolve(target, module), fun: fun, args: args}

  def call({{:., _, [{:__MODULE__, _, _}, fun]}, _, args}, module)
      when is_atom(fun) and is_list(args),
      do: %{module: module && module.name, fun: fun, args: args}

  def call({{:., _, [erlang, fun]}, _, args}, _)
      when is_atom(erlang) and is_atom(fun) and is_list(args),
      do: %{module: ":" <> to_string(erlang), fun: fun, args: args}

  def call({name, _, args}, _) when is_atom(name) and is_list(args),
    do: %{module: nil, fun: name, args: args}

  def call(_, _), do: nil

  @doc "Whether `node` calls `module.fun` for a fun in `funs` (or any, with `:any`)."
  def calls?(node, scope, module, funs) do
    case call(node, scope) do
      %{module: ^module, fun: fun} -> funs == :any or fun in funs
      _ -> false
    end
  end

  @hooks [
    :before_action,
    :after_action,
    :around_action,
    :before_transaction,
    :after_transaction,
    :around_transaction
  ]

  @doc """
  `{hook, functions}` when `node` registers a changeset hook
  (`Ash.Changeset.after_action(changeset, fn ...)`, or the `change
  after_action(fn ...)` builtin), or nil.
  """
  def hook(node, module) do
    case call(node, module) do
      %{module: m, fun: hook, args: args} when m in ["Ash.Changeset", nil] and hook in @hooks ->
        case Enum.filter(args, &function?/1) do
          [] -> nil
          functions -> {hook, functions}
        end

      _ ->
        nil
    end
  end

  @doc "`ast` without the functions given to changeset hooks: what runs where it is written."
  def strip_hooks(ast, module) do
    Macro.prewalk(ast, fn node ->
      if hook(node, module),
        do: put_elem(node, 2, Enum.map(elem(node, 2), &unless_function/1)),
        else: node
    end)
  end

  defp unless_function(arg), do: if(function?(arg), do: nil, else: arg)

  @doc "A local function named in a capture (`&name/2`), or nil."
  def local_capture({:&, _, [{:/, _, [{name, meta, context}, arity]}]})
      when is_atom(name) and is_atom(context) and is_integer(arity),
      do: {name, meta}

  def local_capture(_), do: nil

  @doc "Whether `node` is an anonymous function or a capture."
  def function?({:fn, _, _}), do: true
  def function?({:&, _, [arg]}) when not is_integer(arg), do: true
  def function?(_), do: false

  @doc "The bodies of an anonymous function or a capture."
  def function_bodies({:fn, _, clauses}), do: for({:->, _, [_, body]} <- clauses, do: body)
  def function_bodies({:&, _, [body]}), do: [body]
  def function_bodies(_), do: []

  @doc """
  Whether a call (`module` and `fun`) matches one of `patterns`: a module (atom
  or string) matches all its functions; `"Mod.fun"`, `{Mod, :fun}` and a regex
  (matched against `"Mod.fun"`) match one.
  """
  def matches?(patterns, module, fun) do
    full = "#{module}.#{fun}"

    Enum.any?(List.wrap(patterns), fn
      %Regex{} = regex -> Regex.match?(regex, full)
      {mod, name} -> "#{pattern_name(mod)}.#{name}" == full
      pattern -> pattern_name(pattern) in [full, module]
    end)
  end

  defp pattern_name(atom) when is_atom(atom), do: atom |> inspect() |> String.trim_leading(":")
  defp pattern_name(string), do: string

  @doc "Whether `name` (a path or a module name) matches a regex or contains a string in `patterns`."
  def listed?(patterns, name) when is_binary(name) do
    Enum.any?(List.wrap(patterns), fn
      %Regex{} = regex -> Regex.match?(regex, name)
      pattern -> String.contains?(name, pattern_name(pattern))
    end)
  end

  def listed?(_, _), do: false

  @doc "Every node of `ast` for which `fun` is true, outermost first."
  def find(ast, fun) do
    {_, found} = Macro.prewalk(ast, [], &if(fun.(&1), do: {&1, [&1 | &2]}, else: {&1, &2}))
    Enum.reverse(found)
  end

  @doc "Every node of `ast`, without descending where `skip?` is true."
  def nodes(ast, skip? \\ fn _ -> false end) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        if skip?.(node), do: {nil, acc}, else: {node, [node | acc]}
      end)

    Enum.reverse(found)
  end

  @doc "Every node of a module's own code (nested modules are theirs)."
  def module_nodes(%{body: body}), do: nodes(body, &match?({:defmodule, _, _}, &1))

  @doc "Variable names bound by a pattern."
  def pattern_vars(pattern) do
    pattern
    |> find(fn
      {name, _, context} when is_atom(name) and is_atom(context) -> bindable?(name)
      _ -> false
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp bindable?(name),
    do: name not in [:_, :__MODULE__] and not String.starts_with?(to_string(name), "_")

  @doc "Whether `ast` mentions the variable `name`."
  def mentions?(ast, names) do
    names = List.wrap(names)

    ast
    |> find(&match?({name, _, context} when is_atom(name) and is_atom(context), &1))
    |> Enum.any?(&(elem(&1, 0) in names))
  end

  @doc "A keyword list's value for `key` when `node` is a keyword list literal, or nil."
  def option(list, key) when is_list(list) do
    if Keyword.keyword?(list), do: Keyword.get(list, key)
  end

  def option(_, _), do: nil

  @doc "The issue for `node`: its trigger is the call's name as written."
  def issue(check, issue_meta, node, message) do
    {trigger, line, column} = position(node)

    check.format_issue(issue_meta,
      message: message,
      trigger: trigger,
      line_no: line,
      column: column
    )
  end

  def line(node), do: node |> position() |> elem(1)

  defp position({{:., _, [{:__aliases__, meta, parts}, fun]}, _, _}),
    do: {join(Enum.map(parts, &written/1)) <> ".#{fun}", meta[:line], meta[:column]}

  defp position({{:., meta, [erlang, fun]}, _, _}) when is_atom(erlang) do
    name = ":#{erlang}"
    {"#{name}.#{fun}", meta[:line], meta[:column] && meta[:column] - String.length(name)}
  end

  defp position({{:., _, [{:__MODULE__, meta, _}, fun]}, _, _}),
    do: {"__MODULE__.#{fun}", meta[:line], meta[:column]}

  defp position({name, meta, _}) when is_atom(name),
    do: {to_string(name), meta[:line], meta[:column]}

  defp position({_, meta, _}), do: {Credo.Issue.no_trigger(), meta[:line], nil}

  defp written({:__MODULE__, _, _}), do: "__MODULE__"
  defp written(part), do: part

  @doc "How a call reads in a message: `Mod.fun` as resolved, or `fun` for a local one."
  def name(%{module: nil, fun: fun}), do: to_string(fun)
  def name(%{module: module, fun: fun}), do: "#{module}.#{fun}"
end
