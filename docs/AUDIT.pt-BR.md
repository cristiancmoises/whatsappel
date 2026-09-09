# Auditoria WhatsAppel 3.1 — 09/09/2026

Base: Codeberg `main`, commit `322d64d83a5e1b1f065f3b9113a37ae90570e4d5`.
A revisão cobriu cliente Emacs, integração Org, bridge Guile, módulo PQ em Rust,
dependências, instalação, exemplos de serviços e scripts de publicação.

Foram corrigidos vazamento do token de webhook nos logs, interpolação de shell,
encaminhamento de credenciais locais por proxy, contagem incorreta de mensagens
não lidas, perda de histórico em sincronização, entradas inválidas, caches sem
limite e chamadas de atualização que bloqueavam a interface.

Na integração Org, conteúdo recebido podia expandir expressões executáveis ao
ser capturado. A correção mantém esses dados literais e impede que a exportação
execute Babel/macros ou inclua arquivos locais. No PQ opcional, foram corrigidos
concorrência e gravação de estado, permissões/symlinks, replays e validação de
formatos. Essas mudanças têm testes de regressão.

Resultado: **184 verificações automatizadas aprovadas** e **uma verificação
adicional ignorada** porque este ambiente bloqueia sockets Unix. O teste de
escopo das credenciais passou; o helper completo precisa ser validado em seu
Linux. Compilação, Clippy, formatação, sintaxe fish/Bash e verificação da unidade
systemd passaram. O painel e a conversa foram renderizados em Emacs gráfico,
com dados fictícios, e o rascunho foi preservado após redesenho.

O scan atualizado de 150 dependências Rust retornou **zero vulnerabilidades
reportadas**, mantendo um alerta de dependência de compilação sem manutenção:
`proc-macro-error2 2.0.1`. Isso não comprova segurança formal do protocolo PQ.

Não foram usados seus tokens, conta WhatsApp ou conversas reais. Não houve
push nem implantação em seus servidores. Faltam testes reais de vínculo,
entrega, mídia, reconexão, arquitetura AArch64, Guix Home e addon Go no seu
wuzapi. O bridge ainda recebe o corpo HTTP antes de aplicar o limite e não tem
prazo total para requisições ao wuzapi; mantenha-o no loopback. Ações explícitas
de envio/abrir/salvar ainda são síncronas no Emacs.

O relatório completo, critérios, referências e limites estão em [AUDIT.md](AUDIT.md).
Os logs e capturas estão em `evidence/` no pacote. Trata-se de uma atualização
revisada e testada localmente, não de uma certificação de segurança nem de uma
promessa de produção sem validação em seu ambiente.
