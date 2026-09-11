# WhatsAppel 3.2.0-rc4 — navegação e processamento de respostas

Candidato cumulativo para os hashes retidos de 3.1, RC1, RC2 e RC3. O HEAD remoto
atual não foi confirmado. Alterações locais desconhecidas interrompem a instalação.
Continua sendo um cliente nativo do Emacs, não uma aplicação no navegador.

## Uso

**Switch** e `C-c C-j` permitem selecionar qualquer conversa em cache, inclusive
fora da primeira página e do filtro atual. `j` faz o mesmo na lista. A seleção
exige uma opção conhecida; **New** mantém a abertura por número/JID. Nome e JID
diferenciam contatos homônimos. As anotações mostram não lidas e um trecho curto.
`C-g` cancela sem enviar ou apagar o rascunho. A lista de escolhas não consulta a
rede; abrir a conversa conserva a atualização assíncrona existente.

**Compact rows / Detailed rows**, ou `d` na lista, alterna entre uma e duas linhas
por conversa, mantendo filtro, busca, limite da página e seleção. A preferência é
local ao buffer, sem gravação automática em disco. O filtro **Direct** exclui
entradas `@g.us`; não tenta classificar tipos de entidade não documentados.
A primeira página continua limitada a 80 conversas por padrão.

Uma mudança no total de não lidas não exige mais reconstruir toda a lista: com
ordem e filtro estáveis, atualiza apenas o resumo e as linhas alteradas. Mudanças
fora da página atualizam somente o resumo. Mudança real na ordem, na largura ou
na composição do filtro ainda usa a renderização completa limitada.

`C-c C-f` continua encaminhando, `C-c C-b` volta ao rascunho e `M-g u` navega pelas
não lidas. Há testes ERT novos para essas operações; sua execução nativa e a
validação visual continuam pendentes neste ambiente.

## Desempenho e limites

O worker de leitura passa por longos trechos de texto/base64 usando buscas em C,
em vez de um ciclo Python por byte. Mantém a profundidade máxima de 96 níveis,
a rejeição de chaves duplicadas e o parser JSON estrito. Respostas com muitos
escapes usam o algoritmo linear anterior para evitar regressão nesse caso.
Expoentes que virariam infinito, como `1e309`, e escapes percentuais inválidos na
rota são recusados. Limites de bytes, prazos, TLS e recusa de proxies/redirecionamento
permanecem. Tokens seguem por stdin, não por argumentos ou arquivos temporários.

O benchmark mede somente processamento JSON em Python. Não mede tempo de abertura
da conversa, Emacs gráfico, rede ou entrega do WhatsApp. Respostas pequenas podem
não ficar mais rápidas. O custo de criar um processo por leitura permanece;
Sync/Connect e algumas operações antigas ainda possuem caminhos síncronos.
RC3 → RC4 não altera a ponte, wuzapi nem o pqenv.

## Validar e instalar com fish

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc4.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc4.tar.gz
and cd whatsappel-update-3.2.0-rc4
and python3 scripts/update-package.py "$HOME/whatsappel"
```

A última etapa apenas confere compatibilidade. Para auditar a cópia candidata duas
vezes sem instalar:

```fish
python3 "$HOME/Downloads/whatsappel-update-3.2.0-rc4/scripts/update-package.py" \
    "$HOME/whatsappel" --audit-only --full-audit
```

Após aprovação dos testes nativos:

```fish
fish "$HOME/Downloads/whatsappel-update-3.2.0-rc4/scripts/install-local.fish" \
    "$HOME/whatsappel" --full-audit
```

Ferramentas ausentes bloqueiam a substituição dos arquivos; não há opção para
ignorar a validação. Guarde o backup e o comando exato de rollback impressos.
Reinicie o Emacs. Reinicie a ponte existente somente ao vir de antes do RC2.
Configuração, sessão, pareamento, NPM e alterações independentes no pqenv não são
substituídos. Alterar arquivos na VPS não atualiza o Emacs já aberto no notebook.

O pacote mantém os scripts de IONOS e publicação, mas nenhuma implantação, push,
tag, release ou mensagem real foi executada nesta rodada. A aprovação final exige
Emacs/Guile reais e testes com interface, mpv, microfone e entrega ao destinatário.
