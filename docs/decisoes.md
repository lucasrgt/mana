# MOP — registro de decisões (fase de grilling)

Atualizado em 2026-11-05.

## Decididas

1. **Objetivo.** Ferramenta real para desenvolvimento com agentes de IA (A), com o rigor de um protótipo de pesquisa (B) e porta aberta para virar produto (C).
2. **Condição técnica.** As propriedades provadas precisam chegar ao código executado. Prova que só vale para o modelo não pode ser chamada de "código provado". A primeira demo precisa aceitar a implementação correta e rejeitar uma incorreta sutil, por um mecanismo independente da IA.
3. **Unidade mínima.** Macro de função pura com contrato formal, implementação de referência em Lean, implementação no alvo e evidência de correspondência.
4. **Tipos da etapa 1.** `BitVec 32/64` com interpretação signed/unsigned explícita, overflow sempre explícito (wrapping ou checked), conversões formais `Int` ↔ `BitVec`, `Bool`, records simples. Proposto: vetores ASCII de tamanho fixo. Fora por enquanto: `string`, `float`, `null`, exceções.
5. **Camadas do contrato.** Semântica matemática separada da semântica de máquina, ligadas por lemas de refinamento.
6. **Modelo de geração (generation gap, à la Freezed).** O gerador nunca escreve em arquivos humanos. Lado gerado: contrato e núcleo puro provado, regeneráveis e nunca editados. Lado humano/IA: a casca (I/O, framework, persistência). Divergência aparece como erro de compilação, sem merge. A fronteira gerado/humano coincide com a fronteira provado/testado.
7. **Escopo.** Sem abraçar o mundo (lição do AeroCoding). A MOP é um motor separado. O primeiro consumidor está no ecossistema Mana.
8. **Stack do experimento.** Elixir no backend e Flutter (Dart) no app, o mesmo par do Mana. Descartados: backend Dart, React/React Native, Elixir mobile (LiveView Native arquivado em fev/2026), Kotlin Multiplatform (sem experiência prévia).
9. **Fábrica.** A MOP serve a uma software factory. SaaS web em Elixir com Phoenix LiveView, e Mana (Elixir + Flutter) quando houver mobile. O backend é Elixir em todos os casos.
10. **Linguagens da MOP.** Lean 4 para a regra, a prova e o gerador. Elixir como alvo e como ferramenta (CLI, registro, agentes). Rust fora, salvo necessidade pontual (NIF). Dart é alvo futuro, só para projetos Mana.
11. **Escopo inicial.** A MOP nasce separada. HostPoint e Mana ficam intocados até a primeira demo funcionar.
12. **Ponte de prova via Lynx (proposta, 2026-11-05).** Para o alvo Elixir, a direção se inverte: o código Elixir é escrito normalmente, e o Lynx (josevalim/lynx) traduz o código compilado e as dependências, stdlib incluída, para Lean, onde as leis são provadas e conferidas pelo kernel. Cai o codegen Lean → Elixir. A MOP passa a ser a camada de biblioteca, reúso de leis e provas, manifesto e níveis de evidência sobre o Lynx. Codegen a partir do Lean volta só para alvos sem ferramenta equivalente (Dart).
13. **Primeira macro candidata.** `br.cnpj.valid` com a regra alfanumérica em vigor desde jul/2026 (ASCII − 48, mesmos pesos mod 11).

## Em aberto

- Riscos do Lynx: projeto novo (out/2026), avisa que pode ter bugs na tradução, BIFs faltando, provas quebram ao atualizar Elixir/OTP/deps. A MOP precisa fixar versões e reverificar no CI.
- Ambiente local: Elixir/OTP e elan/lake não estão instalados no host (o Mana roda Elixir em Docker). O Lynx exige Elixir 1.18+ e Lean 4.35.0.

- Ligar a MOP aos agentes via Tidewave/MCP (depois da demo).
- O que é uma macro: unidade provada, ou unidade com evidência em níveis (alinhado ao post do Valim de 24/09/2026).

- Mecanismo de evidência para o alvo: translation validation por artefato ou compilador verificado para um IR mínimo.
- Experimento de controle com Aeneas (Rust → Lean).
- Como a IA encontra macros existentes, escopo do registro, revogação.

## Achados no Mana durante o grilling

- `Mana.BR.cpf?/1` (Elixir) espera dígitos já normalizados, e `BR.isCpf` (Dart) normaliza por dentro. Os contratos de entrada diferem.
- `cnpj?` (Elixir) exige `^\d{14}$` e `isCnpj` (Dart) apaga letras. Os dois rejeitam CNPJ alfanumérico válido.

## Primeira demo (2026-11-05)

Em `mop-lean/mop_br`, com Lynx no commit `0bd83e0`, Elixir 1.20.5, OTP 29.1.2 e Lean 4.35.0:

- Provado para todas as entradas: o dígito verificador fica sempre entre 0 e 9; quaisquer 12 caracteres alfanuméricos completados por `check_digits/1` formam um CNPJ que `valid_codes?/1` aceita.
- Recusado: a variante com `remainder < 1` falha na mesma lei. Contraexemplo: soma 1 → 10.
- Testes empíricos: exemplo oficial `12ABC34501DE35`, CNPJ numérico, rejeições.
- Achado: a regra oficial não distingue 6/A, 7/B, 8/C, 9/D (valores 11 apart).
- Limite: falta provar que a fórmula é a da Receita (lei contra uma spec independente). Hoje isso é coberto só pelo exemplo oficial.

## PubPauta como piloto (2026-11-05)

- O produto Pauta Web passou a se chamar **PubPauta**. A migração para Elixir/LiveView acontece num repositório novo, `pubpauta`, puxada pelas macros (A agora, B como objetivo). O repositório .NET atual segue intocado.

- Stack: .NET (vertical slices, analisadores SKY*) + React 19 (TanStack), framework Skies. ~131 mil linhas de C# fora das migrations, ~88 mil de TS no front. Design system com contrato Assay Design (`.design/contract.toml`, tiers atom/molecule/organism/template).
- Tensão: a ponte de prova escolhida (Lynx) só cobre Elixir. Nada no Pauta pode ser provado diretamente hoje.
- Candidatas a macro encontradas: `MediaAuthorizationBillingPlan.Rescale` (rateio proporcional com resto na 1ª parcela; lei: soma das parcelas = total), espelho financeiro da APT (parcelas de cada perna batem com o total), `BuildingBlocks/Brazil/Cnpj.cs` e `Cpf.cs`.
- O `Cnpj.cs` do Pauta já aceita o alfanumérico e concorda com `Mop.Br.Cnpj`.

## Segunda macro: `Mop.Money.Split` (2026-11-05)

Em `mop-lean/mop_money`:

- Provado para todas as entradas: o `rescale` fecha exatamente com o total.
- Recusado: a variante que esquece o resto (contraexemplo `[1, 1, 1]` em 100 → 99).
- Diferencial contra o `Rescale` do PubPauta (C#, copiado literalmente): 12.000/12.000 iguais no domínio realista. Divergências só com `valor × total` ≳ 10^27: o `decimal` arredonda o quociente (1 centavo a mais numa parcela que não é a primeira) e transborda acima de 7,9·10^28.
- Nome de módulo e pacote: `Mop.Money.Split` em `mop_money`, tudo em inglês.

## Terceira macro: `Mop.Access` (2026-11-05)

Em `mop-lean/mop_access`, a matriz RBAC do PubPauta (ADR 0002) como funções puras e totais.

- Provado: superusuário pode tudo; recurso sem política fecha; `Deny` vence; ação não aplicável nunca é liberada; `Allow` libera ação aplicável; sem override vale o papel; o oferecido à tela é exatamente o autorizado.
- Achado no PubPauta: `UserPermissions.Effective` deixa um override liberar ação não aplicável, e `SetUserPermissions` nunca apaga essas linhas. Latente (só aparece se um recurso deixar de expor uma ação), mas servidor e tela discordam e o admin não consegue remover. Demo em `demo/bug_override_before_applicable.exs`.
- Reuso de prova: uma lei pode citar outra do mesmo grupo como teorema, mas a forma "a expressão Elixir devolveu true" é cara de converter. Funciona melhor guardar lemas Lean em atributos e juntar com `Mop.Proof.join/1` (vai para o pacote `mop`). Reuso entre pacotes continua sem teste.
- Lynx não tem lema geral de que `=:=` implica igualdade; para átomos tem. As leis exigem ações como átomos.
- Pendente: lei para `reconcile/4` (hoje só testes); teste diferencial contra o C#; checagens por registro, no estilo dos `when:` dos Verbs do Mana.
- Login e sessão no `pubpauta`: `mix phx.gen.auth`, sem virar macro por enquanto.

## Ash no PubPauta e princípio de ecossistema (2026-11-05)

- **Princípio:** tudo na MOP é biblioteca Elixir comum. Distribuição por Hex, testes e leis no ExUnit (Lynx), integração com Ash por extensões Spark, Phoenix e Ecto como vêm. Nada de runtime, formato de pacote ou gerenciador próprio.
- **Ash** entra no `pubpauta` (Ash, AshPostgres, AshPhoenix, AshAuthentication), igual ao Mana. Motivos: uma base de backend para a fábrica inteira, Moments reaproveitáveis (o backend deles lê ações, políticas e multitenancy do Ash), multitenancy e políticas nativas cobrindo os ADRs 0001 e 0002. As macros continuam módulos Elixir puros chamados pelo Ash: o Ash garante que todo caminho passa pela checagem; a lei prova que a checagem está certa.
- **Moments não são prova.** Prova = lei do Lynx para todas as entradas; Moments = situações reais verificadas, evidência do nível de teste para fluxos com efeito.
- **Ash na MOP:** como camada de integração opcional, pacote `mop_ash` (checks de política, tipos e validações Ash que chamam as macros). Os núcleos continuam sem Ash, para o Lynx provar e para uso fora do Ash.
