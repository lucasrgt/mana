# mop_br — primeira demo da MOP

Validação de CNPJ alfanumérico (regra da Receita Federal, julho de 2026) em Elixir puro,
com leis provadas pelo [Lynx](https://github.com/josevalim/lynx) e conferidas pelo kernel
do Lean 4.35.0.

## O que está provado

Em `test/laws/cnpj_laws_test.exs`, para todas as entradas:

1. `check_digit_is_a_digit` — para qualquer inteiro, o dígito verificador fica entre 0 e 9.
2. `check_digits_complete_a_valid_cnpj` — para quaisquer 12 caracteres em `0-9`/`A-Z`,
   completar com `check_digits/1` sempre produz um CNPJ que `valid_codes?/1` aceita
   (exceto quando os 14 caracteres ficam todos iguais, que a regra recusa).

A lei 2 prova que gerar e validar são consistentes entre si. Ela não prova que os pesos
e a fórmula são os da Receita: isso está coberto hoje só pelo exemplo oficial em
`test/cnpj_test.exs`.

## O bug recusado

`demo/bug_rem_below_one.exs` troca `remainder < 2` por `remainder < 1`. Com soma de
resto 1, o código devolve 10, que não é dígito. A mesma lei e a mesma prova falham.

## Achado sobre a regra oficial

`test/cnpj_test.exs` mostra que o dígito verificador oficial não distingue `6` de `A`
(e `7`/`B`, `8`/`C`, `9`/`D`): os valores diferem em 11, e todo peso transforma essa
diferença num múltiplo de 11.

## Como rodar

Tudo roda num container (Elixir 1.20.5, OTP 29.1.2, Lean 4.35.0):

```sh
cd ..                      # raiz do repositório
docker build -t mop-lean .
./run.sh mix deps.get
./run.sh mix test                                        # leis + testes
./run.sh env MIX_ENV=test mix run demo/bug_rem_below_one.exs  # o bug sendo recusado
```
