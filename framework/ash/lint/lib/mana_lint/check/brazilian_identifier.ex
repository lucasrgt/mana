defmodule ManaLint.Check.BrazilianIdentifier do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      names:
        ~r/^(valid|validate|is_valid|format|mask|normalize|parse|clean)_?\w*(cpf|cnpj|cep|plate)|^(cpf|cnpj|cep|plate)_?(valid|format|mask|digits)/,
      # The digit groups of a CPF, a CNPJ and a CEP in a regex's source,
      # whatever separates them (`\\.?`, `-?`, `)(`).
      patterns: [
        ~r/\\d\{3\}(?:\\[.\/-]|[()?.\/ -])*\\d\{3\}(?:\\[.\/-]|[()?.\/ -])*\\d\{3\}/,
        ~r/\\d\{2\}(?:\\[.\/-]|[()?.\/ -])*\\d\{3\}(?:\\[.\/-]|[()?.\/ -])*\\d\{3\}(?:\\[.\/-]|[()?.\/ -])*\\d\{4\}/,
        ~r/\\d\{5\}(?:\\[.\/-]|[()?.\/ -])*\\d\{3\}/
      ],
      primitives: [~r/^Mana\.BR(\.|$)/]
    ],
    explanations: [
      check: """
      Flags Brazilian identifiers handled by hand: a function named for
      validating, formatting, masking or parsing a CPF, CNPJ, CEP or plate
      (`valid_cpf?`, `format_cep`, `cnpj_valid?`), and a regex for their
      digit groups (`~r/\\d{3}\\.?\\d{3}\\.?\\d{3}-?\\d{2}/`, `~r/\\d{5}-?\\d{3}/`).

      Check digits, masks and canonical forms written per app drift apart:
      one accepts a formatted CPF, another only digits; the server's rule
      differs from the field's; an invalid document passes a regex.

      Instead, give the attribute its type: `attribute :cpf, Mana.BR.Cpf`
      (and `Mana.BR.Cnpj`, `Cep`, `Phone`, `Plate`) — it accepts formatted
      input, stores the canonical form and rejects invalid check digits, and
      the contract carries `format: br-cpf` so the client (`mana_br`) masks
      and validates the same way. `Mana.BR.cpf?/1` answers for a bare value.

      `Mana.BR` itself is left alone.
      """,
      params: [
        names: "Function names that handle an identifier (a regex).",
        patterns: "Regexes matched against a regex literal's source.",
        primitives: "Modules (regexes or substrings) of Mana's own identifiers."
      ]
    ]

  alias ManaLint.Code

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    names = Params.get(params, :names, __MODULE__)
    patterns = Params.get(params, :patterns, __MODULE__)
    primitives = Params.get(params, :primitives, __MODULE__)

    for module <- source_file |> Code.ast() |> Code.modules(),
        not Code.listed?(primitives, module.name),
        issue <- functions(module, names, issue_meta) ++ regexes(module, patterns, issue_meta),
        do: issue
  end

  defp functions(module, names, issue_meta) do
    for clause <- module |> Code.defs() |> Enum.uniq_by(&{&1.name, &1.arity}),
        Regex.match?(names, to_string(clause.name)),
        do: Code.issue(__MODULE__, issue_meta, clause.head, message(clause.name))
  end

  defp message(name),
    do:
      "`#{name}` handles a Brazilian identifier by hand. " <>
        "Give the attribute a Mana.BR type (Mana.BR.Cpf, Cnpj, Cep, Phone, Plate)."

  defp regexes(module, patterns, issue_meta) do
    for {:sigil_r, meta, [{:<<>>, _, [source]}, _modifiers]} <- Code.module_nodes(module),
        is_binary(source),
        Enum.any?(List.wrap(patterns), &Regex.match?(&1, source)) do
      format_issue(issue_meta,
        message:
          "A regex for a Brazilian identifier's digits. Give the attribute a Mana.BR type (or call Mana.BR.cpf?/1).",
        trigger: "~r",
        line_no: meta[:line],
        column: meta[:column]
      )
    end
  end
end
