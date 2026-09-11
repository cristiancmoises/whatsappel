# RC14 — auditoria da correção de resposta tardia

Candidato: validação nativa e uso real ainda pendentes. O resumo enviado pelo
usuário mostra uma única falha ERT em ambas as passagens do RC13, sem instalação.
O restart posterior carregou os arquivos antigos. O relatório antigo do RC11 não
foi tratado como evidência deste novo resultado.

O teste original verifica o rascunho e whatsapp--last-error. O ramo de resposta
tardia do RC13 mantinha o rascunho e marcava resultado incerto, mas não definia o
aviso. O RC14 restaura essa atribuição no código de produção. O arquivo original
de regressão foi preservado byte a byte, com seis novos testes em outro arquivo.
Não houve reprodução ERT local: o diagnóstico é do código e do teste identificado.

Duas auditorias completas finais: cada uma retornou 1, com 6 PASS, 1 PARTIAL e
20 BLOCKED. Python: 466 descobertos, 389 passaram, 77 ignorados por ausência de
Guile, zero falhas/erros. Os 216 casos ERT fornecidos (6 novos) não foram executados:
Emacs ausente. Guile, fish, mpv e Cargo também estão ausentes. Todos os 88 hashes
de código/build são idênticos antes/depois de ambas as auditorias e no pacote.

A dupla inicial de auditorias foi preservada como desenvolvimento; corrigiu-se
apenas a mensagem de versão do instalador antes da dupla final. Nenhum teste foi
removido, convertido em skip ou teve o limite relaxado. Testes de empacotamento e
transação não equivalem à execução nativa nem a uma instalação aprovada.

O instalador mantém duas auditorias completas e recusa hashes desconhecidos.
A função do guia reinicia o serviço somente após instalação e verificação dos
arquivos. Configuração, init, sessões e PQ independente são preservados. Nenhum
serviço real, conta, webhook ou remoto Git foi alterado. Pale permanece incompleto;
entrega real, mídia, presença e GUI ainda exigem aceitação na instalação do usuário.
