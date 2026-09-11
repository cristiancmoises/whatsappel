# WhatsAppel 3.2.0-rc4 — auditoria executada

**Candidato, sem certificação de produção.** Preparado em 10 de setembro de 2026
(UTC). Nenhum push, deploy, acesso à VPS, reinício, pareamento ou envio real de
mensagem foi executado. A gravação de CI anteriormente recusada não foi repetida.

## Procedência e escopo

Base: arquivos retidos de 3.1, RC1, RC2 e RC3. Foram conferidas todas as 77, 65, 77
e 125 entradas dos respectivos manifestos. O HEAD remoto atual não foi confirmado.
São 16 arquivos alterados desde RC3 e 57 arquivos no manifesto cumulativo. A ponte
é idêntica ao RC2/RC3; wuzapi, sessões, configuração, NPM e código PQ independente
não são substituídos. Hash desconhecido interrompe a atualização.

## Resultados reais

As duas auditorias completas do controlador terminaram com código **1**: **5 PASS,
15 BLOCKED** por rodada. Hashes de código idênticos antes/depois das duas execuções.
Python: **159 encontrados, 135 aprovados, 24 ignorados, nenhuma falha**. Os 24 casos
ignorados dependem de Guile; não contam como validação da ponte.

Passaram os testes Python, a verificação estrutural Lisp, a equivalência do
benchmark JSON, as capacidades FFmpeg e a integridade do código. Emacs, Guile,
fish, mpv e Cargo estavam ausentes, bloqueando suas etapas. Há **108 testes ERT,
17 novos**, mas nenhum foi executado. Uma tentativa inicial interrompida pelo
limite da ferramenta permanece separada nos registros e não conta como auditoria
concluída. A estrutura Lisp não substitui leitura/compilação nativa nem interface.

Os 20 testes Python novos cobrem 3.000 roundtrips com semente fixa dentro de um
teste, limites de profundidade, aspas/escapes, UTF-8, chaves duplicadas, números
não finitos, codificação de rotas e subprocessos reais com servidores HTTP locais.
A suíte retida também executa conversão GIF e codificação Opus sintética; não prova
que um microfone físico funciona nem que o WhatsApp entregou uma mensagem.

## Medição isolada de processamento JSON

Segunda rodada final: Python 3.13.5, sete amostras alternadas, resultados equivalentes.
Valores em milissegundos, mediana. P95 e todas as amostras constam nos registros.

| Cenário | RC3 | RC4 |
|---|---:|---:|
| unchanged_snapshot | 0.051 | 0.052 |
| chat_list_1000 | 9.070 | 5.553 |
| text_4MiB_span | 162.587 | 22.544 |
| media_16MiB_span | 661.188 | 88.203 |
| escape_heavy | 34.013 | 33.869 |

Isso mede somente o parser Python, não abertura da conversa, rede, renderização
Emacs ou entrega. Respostas pequenas não tiveram ganho relevante. Muitos escapes
causaram regressão na primeira tentativa; o fallback corrigiu o caso medido.
Não há promessa de ganho universal ou redução equivalente no aplicativo inteiro.

## Pacote e condição de instalação

Os testes transacionais abrangem os quatro baselines, aplicação/rollback, recusa
de alterações desconhecidas, preservação de configuração/sessão/PQ sintéticos,
patch reversível e comparação dos hashes auditados. Esses testes chamam a função
transacional diretamente, isolando arquivos; não representam aprovação nativa.
A execução separada do instalador real com --apply --full-audit usa um fixture RC3
descartável, termina bloqueada por dependências e deve deixar todos os arquivos
idênticos. Os resultados estão em package-validation.json e nos registros native-*.

O arquivo final possui verificação separada de checksum. Hash não é assinatura de
terceiros. A instalação não possui bypass e exige duas rodadas aprovadas antes de
substituir arquivos. Reinicie Emacs depois; reinicie a ponte real somente ao vir
de uma versão anterior ao RC2. Preserve o backup impresso.

Interface gráfica, scroll, cliques, zoom, mpv, microfone físico, pareamento, Sync,
WhatsApp real, advisories atuais e publicação continuam sem validação. Há caminhos
síncronos antigos e um processo por leitura. As rotas de voz/GIF e as garantias
criptográficas não foram alteradas. Consulte o guia RC4 e conclua a aceitação
nativa/real antes de uso rotineiro. Isto é uma revisão de implementação, não uma
auditoria independente de segurança ou garantia de correção completa.
