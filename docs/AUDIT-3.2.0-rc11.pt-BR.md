# RC11 — auditoria executada

Duas auditorias completas: **6 PASS, 1 PARTIAL e 20 BLOCKED**, código de saída 1.
Em cada execução Python: **462 testes, 387 aprovados, 75 ignorados por falta de
Guile, zero falhas/erros**. Os 32 novos testes Python passaram, inclusive processos
reais e HTTP local. Os 21 novos testes Guile e 18 novos ERT não foram executados
neste ambiente. Emacs, Guile, fish, mpv e Cargo permanecem indisponíveis.

Os 87 hashes de código/build coincidem antes/depois das duas execuções e com a
entrega. O leitor Python do init antigo foi executado isoladamente com dados
sintéticos: usou indevidamente PUBLIC_URL como origem do cliente; a versão v2
recusa essa ambiguidade. Isso não prova que a configuração real do usuário tenha
o mesmo problema. Nenhuma conta real, mensagem, reconexão, callback ou push foi
alterado aqui.

ID aceito não significa entrega. As correções de entrada multipart/envelopes,
recibos e preservação de assinaturas têm testes nativos fornecidos, mas sem
resultado nativo local. Imagens/GIFs nativos não foram verificados graficamente.
Pale continua sem integração funcional por falta de acesso à API real: a
preferência padrão informa indisponibilidade, sem fallback silencioso. Vídeo
funciona somente no caminho mpv quando explicitamente escolhido até a integração
Pale ser concluída. Não se afirma que tudo foi corrigido no celular.

O instalador conserva a exigência de duas auditorias nativas aprovadas. Testes de
pacote/rollback não substituem isso. Leia o relatório inglês e os arquivos brutos
de evidence para resultados, limites e falhas de desenvolvimento preservadas.


A verificação final executou 12 testes de empacotamento/transação com sucesso.
Uma invocação real do atualizador, sem simular sua validação nativa, realizou as
duas auditorias e recusou instalar: 150 arquivos existentes permaneceram intactos,
sem criar backup de instalação. Isso comprova a recusa, não uma instalação nativa
funcional. O init pessoal corrigido é fornecido separadamente, fora do código do
projeto; seus 11 testes Python não substituem a validação do Emacs.
