# RC2: carregamento de conversas e interface

**Versão candidata; a validação nativa de Emacs/Guile não foi executada neste
ambiente. Testes Python e verificações estruturais não comprovam a interface.**

O cliente solicita inicialmente 60 mensagens retidas, em vez de receber todo o
histórico em cada consulta. Load older amplia a janela. Isso não recupera
mensagens ausentes no armazenamento da ponte. Respostas condicionais omitem a
lista quando nada mudou; o cache de resumos é invalidado por alterações reais.
A serialização JSON sai da região protegida pelo mutex.

A lista inicial apresenta 80 conversas em linhas compactas, com busca sobre todo
o cache, filtros All/Unread/Groups, contadores de não lidas, seleção por clique
e More. A barra lateral tem 38 colunas em janelas largas. As conversas existentes
são exibidas antes da atualização de rede. M-g u abre a próxima não lida; C-c /
busca mensagens carregadas; C-c C-f continua encaminhando. O botão Actions por
mensagem fica opcional; o menu permanece no clique direito e em C-c .

Atualizações de texto alteram o trecho necessário, preservando o rascunho e seu
marcador. Na janela móvel, o trecho comum pode permanecer intacto. Uma imagem
carregada altera a propriedade de exibição do marcador, sem apagar a conversa.
O programa continua sendo um aplicativo Emacs, não um site nem uma cópia
completa do telega. As funções anteriores de anexos, voz, imagens, mpv e GIF
permanecem; não foram adicionados flags nativos de PTT ou de repetição de GIF.

A ponte v2 oferece dois slots autenticados para trabalho/resultado de download.
O download automático e a abertura normal por clique não executam a requisição
lenta de mídia no laço principal de atendimento. Resultados não coletados expiram
em 60 segundos. Um upstream travado pode ocupar um slot até a operação terminar;
não há cancelamento forçado dessa chamada Guile. Operações legadas, incluindo
Sync, Connect, encaminhar/salvar e outras ações, ainda podem bloquear. Não existe
promessa de redução percentual de latência nem de funcionamento em toda rede.

## Verificação e instalação

O pacote é um delta ancorado nos arquivos rc1. Divergências são recusadas.
Configuração, sessões, pqenv, wuzapi, NPM e portas não são substituídos.

```fish
set -l bundle "$HOME/Downloads/whatsappel-update-3.2.0-rc2"
python3 "$bundle/scripts/update-package.py" "$HOME/whatsappel" \
    --bundle "$bundle" --audit-only --full-audit
and fish "$bundle/scripts/install-local.fish" "$HOME/whatsappel"
```

A primeira etapa monta um candidato temporário e executa a auditoria completa
duas vezes, sem instalar. A instalação também exige duas passagens nativas do
escopo alterado, agora incluindo Guile. Ferramentas ausentes bloqueiam a escrita.
Guarde o backup e o comando de rollback impressos.

**É necessário reiniciar o Emacs e o inicializador real da ponte.** Copiar o
arquivo Scheme não atualiza o processo já em execução. Os scripts não adivinham
o serviço ativo e não reiniciam wuzapi. O modo normal preserva seu init; o modo
opcional abaixo evita a inicialização de plugins, mas exige o token no .env
protegido/ambiente e não mantém os temas/configurações do init:

```fish
"$HOME/.local/bin/whatsappel" --quick
```

## Diagnóstico sem enviar mensagens

```fish
python3 "$bundle/scripts/doctor-performance.py" \
    --config "$HOME/whatsappel/.env" \
    --output "$HOME/Downloads/whatsappel-latency-"(date -u +%Y%m%dT%H%M%SZ)".json"
```

Use a origem real com --url quando não for loopback. O token também pode ser
informado em entrada oculta. Não o coloque na linha de comando. O relatório
não inclui token, URL, JID, nomes, textos ou respostas brutas; é criado com
permissão0600. Em ponte antiga, read_api=1, /chat não é consultado porque a rota
legada marca mensagens como lidas. Na v2, somente read=0 é usado no diagnóstico.
Essas medidas HTTP não são medidas de renderização do Emacs ou entrega WhatsApp.

Após as etapas nativas, ainda valide com destinatários consentidos: navegação,
rascunho durante chegada de mensagens, janela antiga, imagens, mpv, microfone,
cancelamento, cliques repetidos, entrega efetiva, desconexão e reconexão. Não foi
executado deploy na IONOS nem publicação do patch. Uma branch vazia de auditoria
foi criada no GitHub; a criação do workflow foi recusada e não foi repetida.
