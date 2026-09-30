# WhatsAppel 3.3 — guia de uso

Abra `M-x whatsapp`. O painel oferece botões para nova conversa, pesquisa,
atualização e comandos. Os filtros All, Unread e Groups mostram todas as
conversas, as não lidas ou os grupos. Clique no contato ou pressione Enter na
linha. Tab percorre os botões; `/` pesquisa e `?` abre o menu de comandos.

Na versão 3.3, Inbox oculta as conversas arquivadas por este cliente. `a` arquiva
ou restaura no WhatsApp após confirmação do provedor; `P` fixa localmente; `m`
ou o botão direito abre ferramentas. `C-c C-t` oferece as ferramentas na conversa.
Os filtros Archived e Pinned dão acesso às conversas arquivadas e fixadas. As
preferências persistem por conta em JSON privado. Alterações feitas em outro
dispositivo ainda não são importadas. `i` abre detalhes, foto ampliada e nova tentativa.
As fotos exigem Emacs gráfico com PNG e FFmpeg; o terminal mantém as iniciais.

## Configuração e aliases

```elisp
(add-to-list 'load-path (expand-file-name "~/.emacs.d/local-repo/whatsapp"))
(require 'whatsapp)
```

Abra `M-x whatsapp` ou `M-x whatsappel` a partir da 3.3. Em versões anteriores,
adicione `(defalias 'whatsappel #'whatsapp)` após o `require`. Depois de `git pull`,
reinicie o Emacs para carregar o código atualizado.

Alias de terminal no Fish:

```fish
alias whatsappel 'python3 ~/.emacs.d/local-repo/whatsapp/scripts/launch-whatsappel.py'
funcsave whatsappel
```

No Bash, adicione a `~/.bashrc`:

```sh
alias whatsappel='python3 ~/.emacs.d/local-repo/whatsapp/scripts/launch-whatsappel.py'
```

O launcher lê o `.env` protegido junto do código ou uma conta completa fornecida
pelo ambiente. O instalador local já cria `~/.local/bin/whatsappel`; nesse caso,
basta manter `~/.local/bin` no PATH, sem criar outro alias.
No Guix, o launcher usa o cache de imagens do perfil do Emacs selecionado,
evitando a mistura de módulos SVG incompatíveis entre os perfis Home e sistema.

Na conversa, escreva depois do prompt: Enter envia e `C-j` quebra a linha.
Os botões Send e Attach fazem as mesmas ações. A atualização preserva o
rascunho, a resposta pendente e a posição de leitura. `C-c ?` mostra comandos;
`C-c C-m` abre ações da mensagem: responder, reagir, encaminhar, copiar,
salvar mídia, marcar como lida e excluir, conforme disponível.

## Imagens e arquivos

Use **Original file…** ou `M-x whatsapp-chat-attach-original` para enviar uma
imagem na resolução original ou qualquer outro arquivo pelo caminho de
**documento**. O cliente não redimensiona nem recomprime esses bytes. A largura
da miniatura no Emacs não altera a qualidade do arquivo enviado.

Attach… identifica o tipo e oferece envio de mídia compatível ou arquivo
original. JPEG/PNG podem seguir como foto; MP4 como vídeo; WebP como sticker.
Formatos sem suporte nativo — inclusive arquivos de escritório, compactados,
RAW, SVG, TIFF, AVIF, HEIC e outros — seguem como documentos. GIF real também
segue como documento; a opção GIF aceita MP4 como vídeo, sem garantia de loop. Não há conversão
automática de codecs. A prévia depende dos decodificadores do seu Emacs.

O limite padrão é **16 MiB por arquivo**. Para aumentar, ajuste em conjunto
`whatsapp-max-file-bytes` no Emacs, `WHATSAPPEL_MAX_MEDIA_BYTES` e
`WHATSAPPEL_MAX_BODY_BYTES` no `.env`. Este último precisa comportar o base64
(cerca de 4/3 do tamanho original), mais o JSON. Confirme o limite aceito pelo
seu wuzapi antes de aumentar; o envio ainda usa memória para o arquivo inteiro.

## Desempenho e limites

As consultas de atualização são assíncronas, sem sobreposição por buffer.
Somente buffers visíveis são consultados; históricos iguais não são redesenhados.
As prévias automáticas ficam limitadas às 12 mensagens recentes, com até dois
downloads simultâneos. O cache de mídia usa até 32 MiB de strings de dados.
`M-x whatsapp-clear-caches` limpa as mídias e os textos descriptografados em cache.

Enviar, abrir/salvar mídia, sincronizar e executar o utilitário PQ ainda podem
bloquear a interface até terminar ou atingir o prazo do cliente. Não há promessa
de velocidade percentual nem de memória constante para todo o Emacs.

O bridge continua local e mantém histórico limitado em memória. O wuzapi é a
fonte de histórico após reinícios. Preserve seu `.env`, a sessão já vinculada e
a identidade PQ. O pacote não inclui suas credenciais.

A auditoria usa testes locais e um wuzapi simulado. Antes do uso diário, valide
texto, resposta, foto, documento original, download e reconexão em uma conversa
de teste com um contato que concorde. Compare os hashes do arquivo original e
do arquivo recebido. Isso verifica sua instalação real; não foi feito aqui.

Para aplicar e publicar com fish, leia [DEPLOY.md](DEPLOY.md). Os tokens são
digitados de forma oculta no terminal, nunca no chat.

## Recuperação de conexão e fotos

Connection status distingue o histórico em cache da disponibilidade atual do
backend. O painel oferece Connect existing session quando solicitado e QR de
vinculação quando há necessidade de login. Aceitar uma conexão ou mensagem não
comprova entrega. Após a recuperação observada da sessão, as fotos podem ser
consultadas novamente. Profile diagnostics explica falhas de rota, privacidade,
decodificação e prazo. Retry photo repete apenas a foto do contato selecionado.

Instale a versão `.zupt` pelos comandos do README. O instalador verifica hashes e
executa duas auditorias completas antes de atualizar os arquivos gerenciados.
Ele preserva a configuração privada e cria um backup para restauração. Reinicie
o Emacs depois. `--restart-local` reinicia apenas a bridge Shepherd local verificada.
