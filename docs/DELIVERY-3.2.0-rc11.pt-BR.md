# RC11 — mensagens, mídia e diagnóstico de conexão

**Candidato: a entrega real no celular ainda não foi validada.** O relatório de
saúde HTTP e as conversas antigas em cache não comprovam conexão com o WhatsApp.

Antes de instalar, execute no pacote extraído:

```fish
python3 scripts/doctor-delivery.py --config "$HOME/whatsappel/.env" \
    --output "$HOME/Downloads/whatsappel-delivery-"(date -u +%Y%m%dT%H%M%SZ)".json"
```

O diagnóstico faz somente GETs, não envia mensagens, não marca leitura e não
reconecta a conta. O arquivo privado omite tokens, contatos, URLs e respostas
brutas. BRIDGE_URL é o endereço acessado pelo Emacs; PUBLIC_URL é o endereço do
callback acessado pelo wuzapi. Não são equivalentes. Configure BRIDGE_URL ou
HOST/PORT explicitamente; não cole tokens na linha de comando.

A correção exige um ID real na confirmação do provedor. A interface distingue
aceitação, entrega e leitura. Respostas ambíguas preservam o rascunho, sem reenvio
automático. O recebimento passa a aceitar jsonData em formulário, envelope JSON
e multipart binário, além do JSON direto. Imagens de mensagens efêmeras normais
mantêm os metadados; conteúdo de visualização única não é desembrulhado.

Retry images limpa apenas falhas da conversa atual. Imagens estáticas continuam
nativas. GIFs originais abertos explicitamente usam animação nativa limitada no
Emacs, com pausa ao ocultar/fechar. GIFs que o WhatsApp representa como MP4 continuam
sendo vídeos. Arquivos expirados no provedor não podem ser inventados pelo cliente.

## Pale continua incompleto

A preferência padrão é Pale, mas **esta versão não contém uma integração funcional
com Pale**: não foi possível obter sua API real. A interface informa indisponibilidade
e não abre mpv silenciosamente. Portanto, vídeos ficam indisponíveis por padrão até
existir a integração verificada ou o usuário escolher mpv em Settings → Video.
Imagens/GIFs nativos não usam Pale. Áudio mantém o player mpv explícito.

## Atualização

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc11.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc11.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc11/scripts/update-guix.fish" "$HOME/whatsappel"
```

Não use sudo e não copie source/ por cima da instalação. O instalador executa as
duas auditorias antes da substituição, preserva sessões/configuração/PQ e recusa
alterações desconhecidas. Não altera o perfil Guix nem reinicia serviços sozinho.

Depois do sucesso, reinicie **o processo real da ponte Guile e a instância Emacs**.
A ponte precisa de whatsappel-transport.scm ao lado de whatsappel.scm. Atualizar o
cliente local não atualiza automaticamente a ponte na VPS.

Abra Check delivery. Se callback/assinatura não corresponderem, Repair incoming
callback pede confirmação, preserva as assinaturas atuais e acrescenta Message e
ReadReceipt. Não reconecta nem pareia a conta. Substituir outro callback exige
confirmação extra e pode interromper o consumidor anterior. Registro confirmado
não comprova acesso de rede do wuzapi à ponte. Falta de eventos/recibos não permite
inventar entrega. Consulte DELIVERY-3.2.0-rc11.md para limites detalhados.
