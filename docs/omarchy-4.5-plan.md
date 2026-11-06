Plano de implementação — CyberGhost / Omarchy 4.5

Base: versão 1.7.1, commit 581755f; análise de 6 de novembro de 2026. Este ficheiro é planeamento, não evidência de funcionalidades implementadas. O alvo inicial é Omarchy 4.5 / Qt 6.12.

**Estado do patch 1.7.2 — 6 de novembro de 2026**

CG-01 e CG-02 foram tratados no patch de compatibilidade: Commons.Color explícito, id do campo de password sem colisão, cast do painel e declarações de bloco corrigidas. Verificação local em Omarchy 4.5.0-3 / Qt 6.12.0: 233 testes Python, 76 entradas Qt UI e 13 utilitários; zero avisos de cor indefinida; lint nativo com zero diagnósticos de projeto e as mesmas 53 exceções de metadados. Os itens CG-03 a CG-10 continuam por implementar/validar. Esta evidência não certifica ligações VPN reais nem serviço único.

**Comportamento pretendido**

O utilizador consegue configurar a conta, escolher um país, ligar, trocar de país e desligar através de um painel compacto. O painel mostra o estado observado e permite recuperar de falhas sem adivinhar o que aconteceu. Uma segunda barra ou o restart da shell não inicia outra ligação.

Mantêm-se WireGuard nativo através de NetworkManager, perfil em memória e execução sem helper root. A atualização não acrescenta protocolos, um kill switch ou reconexão automática. A conta do CLI do fabricante mantém-se separada.

**Arquitetura proposta**

- `PluginService.qml` como entry point de serviço, com a fachada pública da shell, preferências e IPC global de operações.
- `Service.qml` conserva inicialmente a lógica existente; a extração para o serviço único é feita antes de alterar o modelo de estado.
- `SetupController.qml` continua responsável por dependências, conta e inventário; não cria trabalho paralelo equivalente por monitor.
- `BarWidget.qml` obtém o serviço único e possui apenas ícone, ancoragem e encaminhamento visual.
- `Panel.qml` cria conteúdo na primeira abertura; a UI envia ações ao serviço e mantém apenas estado visual transitório.
- `cyberghost_runner.py` conserva a API CLI e o controlo NetworkManager. As fronteiras de credenciais, transporte e ciclo de vida permanecem testáveis sem executar uma ligação real.

Adicionar o kind `service` exige atualizar `manifest.json`, `scripts/check_manifest.py`, contratos de testes, instaladores e documentação. Preservar a proibição de modos não suportados; um serviço partilhado não altera o âmbito das ligações.

**Estados e invariantes**

Separar três dimensões: prontidão de configuração; estado observado do túnel (`disconnected`, `connected`, `unknown`, `legacy`); operação em curso (`idle`, `connect`, `disconnect`, `register`, `logout`). Derivar `busy`, switch e mensagens dessas dimensões para evitar combinações contraditórias. Não substituir tudo por um enum que confunda ligação com autenticação.

- Uma ação mutável de cada vez, com identificação da operação e geração. O lock do runner continua a arbitrar chamadas externas concorrentes.
- Selecionar um país não muda a rede. Uma troca exige a ação explícita correspondente.
- Antes da substituição do perfil, cancelar conserva a sessão anterior. Depois dessa fronteira, cancelar tenta remover o perfil novo e reconcilia o estado real.
- Falha ou cancelamento com limpeza inconclusiva produz estado desconhecido e recuperação; não anuncia desconexão nem restauração do túnel anterior sem verificação.
- Falha de GeoIP não muda o estado NetworkManager. Reinício da shell não implica desligar um túnel já estabelecido.
- Desativar o plugin termina trabalho pendente de forma controlada e preserva uma ligação já estabelecida. Reativar consulta NetworkManager. A remoção documenta como desligar o perfil restante.
- Fechar o painel não interrompe uma operação legítima; limpa password não submetida e popups. Credenciais submetidas não aparecem em argv, logs ou notificações.

**Backlog e aceitação**

| ID | Trabalho | Depende de | Aceitação |
| --- | --- | --- | --- |
| CG-01 | Qualificar Commons.Color e corrigir fixtures/geradores afetados | — | Testes Qt originais passam em Qt 6.12 sem OmarchyLoadPatch; nenhum aviso de cor indefinida atribuível ao plugin |
| CG-02 | Triar lint atual, trocar var de bloco e remover colisão do id password | CG-01 | Checker nativo passa; exceções de metadados mantêm justificação exata, sem ignorar missing-property genericamente |
| CG-03 | Provar serviço único e contratos do manifesto num host privado | CG-01 | Serviço existe antes da abertura; dois widgets usam a mesma instância; disable/re-enable e chegada tardia não duplicam processos |
| CG-04 | Mover operações e preferências para o serviço; manter IPC público | CG-03 | Comandos antigos funcionam; uma ação/notificação por pedido; cliques simultâneos e hotplug não duplicam ações; preferência alterada num monitor aparece no outro |
| CG-05 | Explicitar modelo de estado e resultados de ações | CG-04 | Sucesso, timeout, cancelamento, legacy e rollback incompleto têm estado e mensagem corretos; respostas antigas são descartadas |
| CG-06 | Rever deadlines, prioridades e limpeza de processos | CG-05 | Status/GeoIP/inventário não impedem Disconnect; todas as operações têm prazo total e término verificado; nenhum filho de probes fica pendurado |
| CG-07 | Refinar resumo, ação principal e detalhe progressivo | CG-05 | Os estados de setup/ligação ficam evidentes; selecionar país nunca liga; estatísticas/conta têm expansão acessível; ocultação bloqueia exposição e cópia |
| CG-08 | Conteúdo criado na primeira abertura, shell motion e temas | CG-04, CG-07 | UI não é construída no arranque; estado existe sem UI; animações globais respeitadas; quatro posições de barra e tema claro/escuro utilizáveis |
| CG-09 | Catálogos pt/en, teclado e acessibilidade | CG-07 | Idioma muda ao vivo; Tab/Escape/dropdown funcionam; foco permanece visível em painel baixo; nomes acessíveis refletem ação/estado |
| CG-10 | Diagnóstico local, instalação, migração e release | CG-02, CG-06, CG-08, CG-09 | Procedimentos e testes de integração abaixo completos; logs sem segredos; upgrade/rollback preservam conta e configurações |

**UI/UX a implementar**

Topo com ícone, nome, estado e localização ativa. Na primeira utilização, explicar a ação principal por texto contextual junto do controlo de ligar; não adicionar um segundo comando de ligação independente. Acessibilidade e tooltip identificam sempre “Ligar a …” ou “Desligar”. A troca de país tem botão textual apenas quando existe uma alteração pendente.

Resumo com IP e localização, mais o controlo de ocultação. Servidor, fornecedor, taxas e totais ficam numa expansão “Detalhes”. Conta numa linha compacta com gestão acessível. Setup mostra o passo atual e a ação necessária; mensagens de erro surgem junto da ação relevante. A opção de remover o helper antigo permanece em gestão avançada e só aparece quando aplicável.

Usar os componentes de Network/Tailscale como referência. Conservar distinção entre ligação ativa, falta de tráfego e estado desconhecido. Cor complementa texto e ícone; o amarelo de marca não substitui a paleta de erro/foco do tema. O contraste é verificado nas duas paletas.

**Backend e preferências**

- Manter o lock de ciclo de vida, stdin para chaves/passwords, ficheiros privados, validação de servidor/DNS e perfil NetworkManager do próprio utilizador.
- Preservar o formato CLI existente; acrescentar códigos estáveis de erro apenas de forma compatível. A QML traduz códigos, sem depender de comparar mensagens em inglês para classificar falhas.
- Centralizar deadlines e escalada de término. Não matar o runner de uma forma que impeça o rollback: primeiro cancelamento cooperativo, depois prazo de limpeza e só então término forçado com reconciliação.
- Ligar/Desligar/Logout têm prioridade sobre sync de inventário. Cancelar trabalho opcional e retomar apenas quando o estado atual permitir. Manter o backoff existente para sessão expirada/429.
- Uma única verificação periódica por plugin; coalescer pedidos de refresh. Medir antes de substituir polling por eventos NetworkManager; eventos podem ser uma otimização posterior, mantendo reconciliação periódica.
- GeoIP serve informação de apresentação, não prova a integridade do túnel. Reutilizar resultado apenas dentro da mesma geração de rede e respeitar prazos/limites de resposta.
- Preferências do widget mantêm-se em shell.json. Um coordenador aplica configuração e grava através da fachada pública; widgets não competem para gravar defaults. Mudanças recebidas da shell não produzem ciclos de regravação.
- Erro de gravação mantém a escolha em memória e informa que não ficou guardada. Conta/chaves continuam nos caminhos atuais, fora de shell.json.
- Diagnóstico local com versão, estado de dependências, operação/código de erro e durações. Excluir email, tokens, passwords, chaves e payloads sensíveis; IP/endpoints só através de uma opção explícita de diagnóstico.
- Pacote e instruções de instalação incluem o novo entry point, quaisquer módulos e catálogos i18n. Validar a instalação limpa sem depender do checkout. Identificar claramente as secções históricas da checklist de release que ainda descrevem o helper antigo.

**Verificação automatizada**

Manter a suite existente. Acrescentar testes de comportamento nas fronteiras alteradas: serviço partilhado, duas vistas, corridas/cancelamento, persistência e códigos de erro. Não substituir esses testes por asserções sobre nomes de ficheiros.

Comandos base:

```bash
uv run --no-project --python /usr/bin/python3 --with pytest --with requests python -m pytest -q
ruff check .
ruff format --check .
bash scripts/test-qml.sh
python3 scripts/check_manifest.py
python3 scripts/check_qml.py
omarchy plugin validate .
shellcheck install.sh fresh-install.sh scripts/*.sh
git diff --check
```

Usar o Ruff fixado em CI e conservar a matriz de Python declarada. O host nativo de testes deve usar imports QtQuick não remendados, dados sintéticos e um perfil temporário. Adaptar a fixture visual atual para esse host e um output headless; a verificação não deve instalar o fixture na shell principal nem captar o ecrã físico.

**Integração obrigatória antes da release completa**

1. Sem conta, requests ausente, NetworkManager ausente/indisponível e permissões yes/auth/no. Formulário conserva ação e erro corretos, sem guardar password.
2. Conta de teste e ligação real: país escolhido/ativo, perfil próprio em memória, rotas IPv4/IPv6 e DNS observados. Se não existir conectividade IPv6 no ambiente, registar a limitação em vez de declarar o caso validado.
3. Desligar elimina o perfil/interface e as rotas/DNS próprios. Não altera outras ligações NetworkManager.
4. Falha de autenticação, timeout, cancelamento antes/depois da substituição e rollback incompleto, sob controlo. A UI reflete o estado observado e fornece recuperação.
5. Restart da shell com túnel ativo preserva a ligação e reconcilia a UI; restart NetworkManager termina o perfil em memória e atualiza o estado.
6. Dois monitores, cliques simultâneos, hotplug e disable/re-enable sem duplicação de ações ou notificações.
7. Upgrade da 1.7.1, cenário legacy e instalação limpa num perfil descartável. Testar rollback de versão/configuração, sem remover dados de conta.

O patch de compatibilidade pode ser entregue antes do redesenho, com evidências e âmbito próprios. A conclusão deste plano exige a integração real; essa integração ainda não foi executada.
