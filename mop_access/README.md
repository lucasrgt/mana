# mop_access — permissões por recurso e ação (`Mop.Access`)

Matriz de permissões no formato do RBAC do PubPauta (ADR 0002): padrões por papel, refinados por
overrides esparsos por usuário. Funções puras e totais; uma linha malformada fecha o acesso.

## O que está provado

`test/laws/access_laws_test.exs`, um único grupo conferido pelo kernel do Lean via Lynx, para
quaisquer entradas:

| Lei | Garantia |
|---|---|
| `superuser_may_do_everything` | superusuário pode tudo |
| `ungoverned_resource_is_closed` | recurso sem política: ninguém mais pode nada |
| `deny_always_wins` | um `Deny` sempre bloqueia |
| `inapplicable_action_is_never_allowed` | ação que o recurso não expõe nunca é liberada, com qualquer override |
| `allow_grants_an_applicable_action` | um `Allow` libera uma ação aplicável |
| `role_default_decides_without_override` | sem override, vale o padrão do papel |
| `offered_matches_allowed` | o que a tela oferece é exatamente o que `allowed?` libera, entre as ações aplicáveis |

Mais dois lemas, `member_is_boolean` e `policy_is_nil_or_pair`. Os lemas usados por várias leis
ficam escritos uma vez em atributos `~LEAN` e entram em cada prova via `Mop.Proof.join/1`.

`reconcile/4` (gravar só as células que diferem do papel) tem testes em `test/access_test.exs`,
ainda sem lei.

## O que isso achou no PubPauta

`UserPermissions.Effective` aplica o override antes de olhar as ações aplicáveis, enquanto o
`MatrixAsync` filtra por elas, e o `SetUserPermissions` só reconcilia células aplicáveis. Se um
recurso deixar de expor uma ação, uma linha `Allow` antiga continua liberando no servidor, sem
aparecer na tela nem poder ser removida pelo editor. `demo/bug_override_before_applicable.exs`
reproduz essa regra: a lei `inapplicable_action_is_never_allowed` falha, e o teste do
contraexemplo mostra o `:delete` liberado enquanto a tela oferece só `[:view]`.

## Como rodar

```sh
cd ..                                   # raiz do repositório
MOP_PROJECT=mop_access ./run.sh mix test
MOP_PROJECT=mop_access ./run.sh env MIX_ENV=test mix run demo/bug_override_before_applicable.exs
```
