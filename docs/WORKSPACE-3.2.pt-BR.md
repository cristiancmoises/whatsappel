# WhatsAppel 3.2.0-rc1 — uso, instalação e publicação

## O que muda

Esta é uma interface **nativa do Emacs**, não um site. O bridge Guile, o wuzapi,
as sessões e o código/identidades pqenv não são substituídos. Um worker Python
executa o upload e a preparação explícita de GIF sem bloquear a thread principal
do Emacs. Comandos legados, como QR, Sync, Save e Forward, ainda podem ser síncronos.

O workspace inclui iniciador no menu de aplicativos, barra lateral de conversas,
filtros e botões Image / Video / GIF / Record voice / File. Anexos passam pela
etapa Preview → Caption → Send; selecionar um arquivo não o envia. O destino e
a conta ficam vinculados à etapa de envio. Mudanças de conta invalidam anexos
já preparados. Envios de texto preservam alterações mais recentes no rascunho.
Falhas de confirmação não provocam reenvio automático: confira a conversa antes
de tentar novamente, pois um timeout pode ocorrer após a entrega.

A conversa mostra inicialmente 100 mensagens; Show older expande as mensagens
já retidas pelo bridge, não um histórico ilimitado no servidor. A prévia possui
cache de até oito entradas, limitado por pixels declarados; atualizações de
imagens são agrupadas. Isso não promete um limite fixo para toda a memória do Emacs.

Imagens PNG/JPEG/WebP estáticas recebem Fit, zoom e Save original. O limite de
canvas é 16 milhões de pixels e 16.384 pixels por eixo. Formatos não suportados
ou imagens maiores podem ser salvos como originais, sem execução de documentos.
Vídeos e áudios usam mpv com cópias locais privadas removidas ao encerrar o player.
Os argumentos desabilitam configuração/scripts automáticos e referências externas;
isso não equivale a um sandbox contra todas as falhas de decodificadores.

Record voice inicia o microfone somente após o clique. Use Stop recording,
Preview e Send. O padrão é até 180 segundos, áudio Opus mono a 48 kHz; o máximo
configurável é dez minutos. O bridge atual envia áudio sem flag PTT: não há
promessa de aparecer como mensagem de voz nativa do WhatsApp. Anexos comuns não
recebem automaticamente um envelope pqenv.

GIF bruto continua sendo documento original. Prepare MP4 copy cria, por escolha
explícita, outra cópia silenciosa de até 30 segundos, ajustada a 720×720, dimensões
pares e limite de 16 MiB. O original não muda. O endpoint /send/gif do bridge
é um alias de vídeo MP4, portanto loop/GIF nativo no destinatário não é garantido.

## Instalação local

Requisitos: Emacs gráfico 28.1+, Python 3.10+, fish, Git/coreutils, mpv e FFmpeg
com PulseAudio, libopus e libx264. PipeWire pode fornecer o servidor PulseAudio.
Permissões e dispositivo de microfone precisam ser validados na máquina real.

Após extrair o pacote em Downloads, execute no fish:

```fish
cd ~/Downloads/whatsappel-update-3.2.0-rc1
python3 scripts/update-package.py ~/whatsappel
and fish scripts/install-local.fish ~/whatsappel
```

O primeiro comando só verifica hashes/compatibilidade. O segundo prepara uma cópia
isolada, roda os testes nativos do código alterado e somente depois substitui os
arquivos gerenciados. Ferramentas ausentes ou testes falhando interrompem antes
da alteração. Não há placeholder BASELINE_COMMIT. Uma instalação sem .git também
é aceita, desde que contenha o código/testes completos da versão 3.1.0 compatível.
Alterações desconhecidas não são sobrescritas.

Reinicie a instância do Emacs e clique em WhatsAppel no menu de aplicativos,
ou execute `~/.local/bin/whatsappel`. A configuração normal do Emacs é preservada.
O iniciador lê apenas atribuições literais permitidas do .env, sem executá-lo.
O token/configuração já existente e o pareamento inicial continuam necessários.
Esta atualização não cria contas nem relinka sessões por conta própria.

## VPS IONOS

```fish
cd ~/Downloads/whatsappel-update-3.2.0-rc1
fish scripts/deploy-ionos.fish
```

Destino fixo: root@securityops.co, porta 5119, com verificação de chave SSH
obrigatória. O script transfere um pacote com SHA-256, rejeita extração insegura
e procura uma única instalação em /root/whatsappel ou /opt/whatsappel. Use
`--target` com o caminho absoluto verdadeiro quando necessário. Esses caminhos
são candidatos de descoberta, não uma afirmação sobre a instalação da VPS.
`--stage-only` copia/verifica sem substituir a instalação.

Os testes nativos exigem Python, Git, fish, FFmpeg, mpv e Emacs na máquina de
destino; em servidor sem interface, Emacs não gráfico pode executar testes batch.
O script não instala pacotes do sistema automaticamente. Se a auditoria ficar
bloqueada, mantém a produção e informa onde estão o pacote e os relatórios.

Como o bridge/wuzapi não mudam, **não há restart de serviços, rebuild de Docker,
alteração do NPM, exposição de porta web, limpeza de sessão ou troca de chave PQ**.
A interface e o microfone ficam na estação de trabalho. Para acessar um bridge
na VPS que já escuta em loopback:7337, pode-se usar:

```fish
ssh -N -T -p 5119 -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L 127.0.0.1:17337:127.0.0.1:7337 root@securityops.co
```

No Emacs, configure a origem como http://127.0.0.1:17337 e utilize o token
existente desse bridge por configuração protegida. Não coloque tokens em URLs
ou no histórico do shell. A porta local separada evita ocupar 7337 de um bridge
local já existente. Confira a porta real do servidor antes de usar o túnel.

## Commit e envio aos quatro remotos

```fish
cd ~/Downloads/whatsappel-update-3.2.0-rc1
fish scripts/commit-and-push.fish ~/whatsappel --branch main
```

É criada/reutilizada uma worktree separada em ~/whatsappel-publish-3.2.0-rc1.
Ela parte do HEAD commitado; trabalho não commitado na pasta original é preservado
e não é incluído silenciosamente. Para uma instalação sem .git, é criado um
clone separado do Codeberg. A identidade Git real precisa estar configurada.
Somente os caminhos do manifesto são adicionados ao commit, após a auditoria.

Os quatro destinos são os repositórios whatsappel de git.securityops.co,
git.securityops.com.br, GitHub (cristiancmoises) e Codeberg (berkeley). Os tokens
são solicitados com entrada oculta; o helper usa credenciais por repositório em
memória, sem token em argv, URL Git, arquivo persistente ou log. TLS continua
validado e redirecionamentos autenticados são recusados. Falha 5xx não significa
automaticamente token inválido. Falhas de cada remoto são informadas separadamente.

Para autorizar explicitamente a criação de repositórios públicos ausentes:

```fish
fish scripts/commit-and-push.fish ~/whatsappel --branch main --create-missing --visibility public
```

A visibilidade existente não muda. Remotos divergentes ou adiantados exigem
reconciliação; nunca há force push. --commit-only interrompe após o commit local;
--remote github limita o envio a esse destino. Tags/releases hospedadas não são
criadas automaticamente. Reexecutar preserva a worktree de publicação.

## Rollback e limites da validação

Cada instalação concluída imprime o comando exato do rollback e seu backup
privado. Use esse comando, sem inventar timestamps. Ele verifica hashes e recusa
sobrescrever alterações feitas depois do update. Restaura apenas arquivos
gerenciados e bytecode antigo; configuração/sessões continuam fora da operação.

Esta é uma release candidate. Python, HTTP local simulado, FFmpeg sintético,
extração e Git foram testados; runtimes nativos indisponíveis aparecem como
BLOCKED, não PASS. Veja AUDIT-3.2.0-rc1.pt-BR.md. Pareamento/entrega reais,
interface gráfica, mpv com janela e microfone físico precisam de teste na sua
máquina antes de uso rotineiro. Não houve deploy ou push real nesta preparação.
