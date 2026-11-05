# mop_money — rateio provado (`Mop.Money.Split`)

`Mop.Money.Split.rescale/2` é a versão Elixir do `MediaAuthorizationBillingPlan.Rescale` do
PubPauta: cada parcela é escalada proporcionalmente com arredondamento para baixo, e o resto vai
para a primeira.

## O que está provado

`test/laws/split_laws_test.exs`, conferido pelo kernel do Lean via Lynx: para **qualquer** lista
não vazia de inteiros com soma positiva e **qualquer** total positivo, as parcelas somam exatamente
o total. Não há limite de tamanho: os inteiros do Elixir não transbordam.

## O bug recusado

`demo/bug_forgets_remainder.exs` esquece de dar o resto à primeira parcela. A mesma lei e a mesma
prova falham; o contraexemplo `rescale([1, 1, 1], 100) == [33, 33, 33]` soma 99.

## Teste diferencial contra o C#

`differential/extract_rescale.py` copia o `Rescale` literalmente do repositório do PubPauta para
`differential/csharp/Program.cs` (só `private` vira `internal`). `differential/cases.exs` gera os
casos e as respostas do Elixir, e compara com o que o C# devolve.

| Família | Casos | Concordam |
|---|---|---|
| Realista (até 12 parcelas de até R$ 100 mil) | 10.000 | 10.000 |
| Valores pequenos (1–5 centavos) | 2.000 | 2.000 |
| Precisão do `decimal` (produto ≈ 10^28) | 200 | 0: o C# põe 1 centavo a mais na 2ª parcela |
| Overflow do `decimal` (produto > 7,9·10^28) | 50 | 0: o C# lança `OverflowException` |

As divergências exigem `valor × total` acima de cerca de 10^27 centavos², algo como parcelas e
total na casa de centenas de bilhões de reais. No domínio do PubPauta o C# coincide com a macro.

## Como rodar

```sh
cd ..                                   # raiz do repositório
MOP_PROJECT=mop_money ./run.sh mix test
MOP_PROJECT=mop_money ./run.sh env MIX_ENV=test mix run demo/bug_forgets_remainder.exs

python3 -I mop_money/differential/extract_rescale.py <caminho do pauta-web-monorepo>
MOP_PROJECT=mop_money ./run.sh sh -c 'mkdir -p tmp/diff && mix run differential/cases.exs gen tmp/diff'
docker run --rm -i -e HOME=/tmp -v "$PWD/mop_money":/w -w /w/differential/csharp \
  mcr.microsoft.com/dotnet/sdk:10.0 sh -c 'dotnet run -c Release < /w/tmp/diff/cases.txt > /w/tmp/diff/actual.txt'
MOP_PROJECT=mop_money ./run.sh mix run differential/cases.exs compare tmp/diff
```
