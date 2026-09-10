# WhatsAppel 3.2.0-rc1 — auditoria e validação

Data da versão: 09/09/2026, America/Sao_Paulo.

## Resultado

**Candidata a lançamento, não uma versão com auditoria completa aprovada.** O
controlador de auditoria completa retornou código 1: 2 verificações aprovadas e
13 bloqueadas por ferramentas ausentes. O instalador não oferece opção para
ignorar essas verificações nativas e não substitui arquivos instalados quando a
validação do código alterado falha ou fica bloqueada.

A suíte Python encontrou **80 testes: 66 aprovados, 14 ignorados e nenhuma falha**.
Os 14 ignorados dependem do Guile, ausente neste ambiente. A integração HTTP real
da ponte permanece marcada separadamente como BLOQUEADA. Foram adicionados 40
testes Python (31 de unidade/instalador/worker e 9 de integração).

Foram executados testes reais do processo Python com servidor HTTP de loopback:
um único envio preservando os bytes originais, redirecionamento recusado,
resposta JSON inválida tratada como entrega incerta e erro do servidor sem
reenvio automático. FFmpeg realmente converteu GIF em MP4 e codificou áudio Opus
sintético. Isso não testa o microfone físico nem a entrega pelo WhatsApp.

Um teste Git real confirmou que um worktree e commit separados preservam as
alterações não commitadas do diretório original. **Somente nesse teste a barreira
nativa foi simulada**, para testar isolamento; não houve validação do Emacs por
esse caminho nem push real. Arquivos de teste sintéticos não são dados da conta.

Emacs, Guile, fish, Cargo/Rust e mpv não estão disponíveis neste ambiente. Os 18
novos testes ERT e os 28 existentes (46 no total) **não foram executados**. O
verificador estrutural Python encontrou delimitadores balanceados, mas não é
compilador, leitor Lisp ou substituto do ERT. O relatório em inglês e os arquivos
JSON/log detalham cada verificação individualmente.

A auditoria shell anterior também foi executada. Espaçamento do diff e sintaxe
Bash passaram. O alvo conjunto de publicação executou os testes Python com
sucesso e depois falhou porque fish não está instalado. A falha foi mantida no
relatório, não convertida em aprovação. RustSec on-line não foi executado.

## Origem e preservação

A base é o pacote 3.1.0 anterior, com manifesto SHA-256 verificado. O arquivo
whatsapp.el e o publicador coincidiram com os blobs consultados no espelho GitHub
(tree/commit a5af1a66a40dc7d54c3a67c84876d1c5131ba06a). Não foi possível verificar
o HEAD atual do Codeberg nem afirmar igualdade de todo o repositório. O espelho
pode ter mudanças PQ posteriores ao pacote retido.

Por isso, a entrega contém apenas um delta gerenciado. Hashes anteriores e novos
protegem contra sobrescrever mudanças locais desconhecidas. Não substitui código
PQ, ponte Guile, integração Org, wuzapi, .env, identidades, sessões ou bancos.
O repositório Git usado para gerar/testar o patch é um fixture local, não um
commit publicado no servidor. As versões/códigos de ferramentas constam nas
 evidências distribuídas.

## Alterações e limites

O candidato implementa envio assíncrono comum, proteção contra envios duplicados,
manutenção de rascunhos, renderização inicial limitada, reaproveitamento de
prévias, validação de dimensões antes do decoder nativo, zoom e salvamento de
originais. Não foi medido percentual de aceleração nem limite de memória total.

Há controles de anexo com destinatário fixado, Prévia/Legenda/Enviar/Cancelar,
gravação explícita e limitada e conversão opcional de GIF sem alterar o original.
mpv usa argumentos sem shell, arquivo local privado, desabilita scripts,
configuração automática e referências externas. Essas opções não constituem
uma sandbox completa para vulnerabilidades de codecs.

O token não é inserido em URLs, argumentos de processos ou arquivos de credencial.
O instalador cria backups privados, executa testes em candidato isolado e recusa
mudanças desconhecidas. O publicador usa worktree separado, tokens ocultos por
host e não força pushes. O deploy mantém a verificação da chave SSH, valida o
tar e não reinicia ponte/wuzapi, Docker ou Nginx Proxy Manager.

**Não executado:** uso gráfico do Emacs, comportamento real de cliques/zoom,
janela mpv, microfone físico, pareamento e envio real pelo WhatsApp, acesso ao
IONOS, publicação nos quatro remotos e consulta atual do RustSec.

A interface continua sendo um aplicativo desktop Emacs, não um serviço web.
Atualizar apenas os fontes na VPS não atualiza o Emacs do notebook. Voz usa áudio
Opus da rota existente, sem garantia de flag PTT/selo de mensagem de voz. GIF
convertido usa a rota MP4 existente, sem garantia de looping nativo no WhatsApp.
Os anexos comuns não recebem uma nova camada pqenv. Comandos legados como QR,
Connect, Sync, Save, Forward, envio de texto cifrado e operações Org continuam
com trechos síncronos. Configurações pessoais do Emacs podem afetar o resultado.

## Reproduzir

```fish
python3 scripts/audit-workspace.py . --scope full
```

Execute esse comando em um checkout completo atualizado. O instalador do pacote
faz verificação de compatibilidade sem alterações por padrão; --apply executa a
barreira nativa antes de modificar fontes. Logs finais e validação do pacote
estão em evidence/. O relatório completo em inglês está em AUDIT-3.2.0-rc1.md.

Esta é uma revisão de desenvolvimento com testes reproduzíveis, não uma auditoria
independente, certificação de segurança ou garantia de funcionamento.
