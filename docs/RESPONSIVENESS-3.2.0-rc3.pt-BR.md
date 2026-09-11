# WhatsAppel 3.2.0-rc3 — uso e atualização

**Candidato a lançamento; validação nativa e em conta real ainda incompleta.**
Este continua sendo um aplicativo Emacs, não uma aplicação de navegador. A base
é o pacote RC2 retido, não uma confirmação do HEAD atual da Codeberg.

## Melhorias

Leituras de conversas passam por processos Python separados, com limites de corpo,
prazo total no filho POSIX, cancelamento pelo Emacs e validação de JSON. Não há
redirecionamento, proxy herdado do ambiente nem reenvio automático de mensagens.
O processo auxiliar recebe o token por stdin, não por argumento ou arquivo.
A criação de um processo por leitura também tem custo; não foi medido um ganho
percentual de velocidade nem uma redução da latência da sua conexão.

A lista atualiza somente linhas alteradas quando ordem e estrutura permanecem
iguais. Reordenações e mudanças estruturais ainda podem exigir redesenho limitado.
O carregamento inicial continua limitado a 80 conversas e 60 mensagens retidas.
A pré-carga de imagens considera as áreas realmente visíveis, com agrupamento de
rolagem em 150 ms de ociosidade. Clicar em uma imagem já na fila aproveita o mesmo
pedido e abre quando ficar pronta, sem exigir outro clique enquanto a conversa
original continuar selecionada. Trocar de conversa impede roubo de foco.

A abertura normal inicia uma única atualização periódica, respeitando uma pausa
explícita. O cabeçalho diferencia carregamento, cache, falha e conversa realmente
vazia. Conversas em segundo plano usam read=0 na API v2. Marcação automática de
leitura exige janela selecionada e foco confirmado; terminais com foco desconhecido
mantêm a ação manual. Pontes antigas podem ignorar esse parâmetro: atualize e
reinicie a ponte antes de depender dessa garantia. Write ou C-c C-b volta ao rascunho.

O limite das respostas de histórico é 4 MiB; resultados de mídia, 24 MiB. Respostas
excessivas ou inválidas conservam o cache anterior. Fechar uma conversa encerra seus
próprios filhos de leitura. Imagens, mpv, confirmação de anexos e gravação explícita
continuam, sem prometer novos sinalizadores nativos PTT/GIF ou criptografia pqenv
para anexos comuns.

## Pacote cumulativo e instalação

O pacote aceita hashes exatos das versões retidas 3.1, RC1 e RC2, além do próprio
resultado RC3. Alterações desconhecidas interrompem a instalação. Configuração,
sessão e código PQ independente não são substituídos. Não é necessário instalar
cada candidato anterior em sequência.

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc3.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc3.tar.gz
and cd whatsappel-update-3.2.0-rc3
and python3 scripts/update-package.py "$HOME/whatsappel"
```

Esse último comando apenas confere. Para montar uma cópia isolada e auditar duas
vezes sem instalar:

```fish
python3 scripts/update-package.py "$HOME/whatsappel" --audit-only --full-audit
```

São necessários Emacs, Guile/guile-json, fish, Python, FFmpeg, mpv e, na auditoria
completa, Rust/Cargo e dependências do projeto. O script não instala pacotes por
conta própria. Falta de ferramentas ou falha de testes interrompe a operação.
Depois da aprovação dos testes nativos:

```fish
fish scripts/install-local.fish "$HOME/whatsappel"
```

A instalação repete duas verificações e imprime o backup e o comando exato de
rollback. Reinicie o Emacs. Ao atualizar uma versão anterior à RC2, reinicie também
o serviço/processo real da ponte, pois o pacote cumulativo inclui a ponte RC2.
Da RC2 para RC3 a ponte não muda. Nenhum nome de serviço é presumido, nenhum NPM
ou Docker é alterado e nenhuma conta é pareada novamente. Atualizar somente a VPS
não muda o Emacs que já está em execução no notebook.

O diagnóstico doctor-performance.py permanece somente leitura e gera relatório
sem token, nomes, JIDs ou mensagens. A documentação em inglês traz comandos de
medição, envio seguro à VPS e publicação isolada. Nenhum push ou deploy remoto
foi executado nesta iteração. A auditoria separa testes realmente executados de
verificações nativas bloqueadas. Testes de interface gráfica, microfone físico,
mpv em janela e entrega real pelo WhatsApp ainda são requisitos de aceitação.
