# MOP — Macro Oriented Programming

Uma biblioteca de macros para a fábrica de software: peças reutilizáveis em Elixir, cada uma com a
evidência mais forte que ela permite. Regras puras têm leis provadas para todas as entradas pelo
[Lynx](https://github.com/josevalim/lynx) e conferidas pelo kernel do Lean; o resto tem testes, e
os fluxos terão Moments.

Tudo é ecossistema Elixir comum: cada macro é um pacote Mix, as leis rodam no ExUnit, e a
integração com Ash será um pacote à parte (`mop_ash`). Os núcleos não dependem de Ash nem de
Phoenix.

| Pacote | Módulos | Provado |
|---|---|---|
| [`mop_br`](mop_br) | `Mop.Br.Cnpj` | dígito verificador sempre de 0 a 9; gerar e validar são consistentes |
| [`mop_money`](mop_money) | `Mop.Money.Split` | o rateio fecha exatamente com o total |
| [`mop_access`](mop_access) | `Mop.Access` | permissões por papel e override: fail-closed, deny vence, ação não aplicável nunca, tela = servidor |

O registro das decisões está em [docs/decisoes.md](docs/decisoes.md).

## Usar num projeto

```elixir
{:mop_access, git: "https://github.com/lucasrgt/mop.git", sparse: "mop_access"}
```

O Lynx é dependência só de teste de cada pacote: o projeto que usa a macro não o baixa.

## Rodar as leis

As provas precisam de Elixir 1.20, OTP 29 e Lean 4.35.0. O `Dockerfile` monta esse ambiente:

```sh
docker build -t mop-lean .
MOP_PROJECT=mop_access ./run.sh sh -c 'mix deps.get && mix test'
```
