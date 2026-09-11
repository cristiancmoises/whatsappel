# WhatsAppel 3.2.0-rc5 — auditoria executada

**Release candidate. Validação nativa e em conta real está incompleta.**
Foram concluídas duas passagens completas com os mesmos 62 hashes de código/build:
5 etapas PASS, 1 PARTIAL, 15 BLOCKED, saída 1 em ambas. Cada suíte Python descobriu
236 testes: 212 passaram, 24 dependeram de Guile e foram ignorados, zero falhas e
zero erros. Os 77 testes novos passaram também em execução instrumentada separada.

O parser do upload anterior aceitou respostas ambíguas com status 500 seguido de
200 e valores NaN. Isso foi reproduzido com opener simulado: RC4 aceitou, RC5 manteve
o envio incerto, sem repetir o POST. Os testes novos incluem servidores HTTP reais
em loopback e subprocessos; não envolveram WhatsApp real.

Workers compartilham agora JSON estrito e prazos. Unicode válido é preservado;
chaves duplicadas, valores não finitos, excesso de profundidade e substitutos sem
par são recusados. Upload POSIX na thread principal limita o tempo do POST/resposta,
mas não inclui preparar o arquivo. Outras threads/plataformas têm limitações.

O controller registra skips como PARTIAL, não PASS. Logs privados têm teto de 8 MiB
e comandos têm prazo de 600 segundos, com encerramento do grupo POSIX pertencente
ao processo. Isso não é sandbox. Variáveis comuns de segredos são removidas, mas
os testes continuam código confiável executado com os direitos do usuário.

O instalador verifica dois relatórios distintos, escopo, sequência completa de
etapas e hashes antes/depois, detecta alterações na candidata, documentação, pacote
e código original e instala bytes congelados da candidata auditada. Recibos
sintéticos são usados apenas em fixtures explícitas de transação/Git; não há bypass
no instalador. Nenhuma aprovação nativa é inferida dessas fixtures.

Emacs, Guile, fish, mpv e Cargo não estavam disponíveis. O acesso à distribuição
Debian falhou na resolução DNS. Os 108 ERT retidos não foram executados; o código
Emacs muda apenas sua versão nesta rodada. Bridge, wuzapi e pqenv não foram alterados.
Não houve pesquisa de advisories atuais, teste de microfone físico, GUI, pairing,
entrega real, deploy, push ou nova tentativa do workflow anteriormente recusado.

A medição de envelope usa um contador em memória após validação e exclui parsing,
IPC, rede, início do Python, renderização do Emacs e entrega. Evitar a segunda
serialização economizou cerca de 26 ms no fixture de 4 MiB e 110 ms no de 16 MiB;
isso não significa esse ganho no carregamento completo da conversa. Hash de arquivo
sintético de 32 MiB manteve o resultado e reduziu a alocação incremental rastreada
de cerca de 32 MiB para 1 MiB. Não são tetos de RSS. Amostras completas estão nos logs.

Cobertura instrumentada dos testes novos inclui somente o processo pai; não
representa os workers filhos, o projeto completo nem os componentes nativos.
Consulte `changed-python-coverage.json`. Os logs de tentativas interrompidas e
fixtures inicialmente incorretas foram preservados; falhas não foram ocultadas.

A fonte vem do snapshot 3.1 verificado com o payload cumulativo RC4 verificado.
HEAD atual dos remotos não foi confirmado. O manifesto aceita apenas hashes
explicitamente registrados e recusa variantes desconhecidas. Configurações,
sessões, originais e pqenv independentemente atualizado são preservados.

Os 11 testes de pacote/transação passaram. A invocação real do instalador na
fixture RC4 concluiu duas auditorias e recusou a instalação, preservando os 95
arquivos existentes sem criar backup. As evidências separam transações com
recibos sintéticos desse teste real, sem mocking da etapa nativa. Nenhum hash ou relatório constitui assinatura/certificação
independente nem proteção contra alteração por um processo com o mesmo usuário.
Leia o relatório em inglês para os resultados detalhados e os limites de cada teste.

```fish
python3 scripts/update-package.py ~/whatsappel --audit-only --full-audit
```

Execute a partir do pacote extraído. Instalação só prossegue após as etapas nativas
obrigatórias passarem; mantenha o backup e valide o funcionamento real antes de
usar como versão de produção.
