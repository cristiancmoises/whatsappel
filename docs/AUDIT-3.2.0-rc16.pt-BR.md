# RC16 — auditoria executada

Versão candidata: não houve validação com conta real, telefone destinatário ou janela
gráfica do usuário. As duas execuções completas retornaram 1: 6 PASS,
1 PARTIAL e 21 BLOCKED. Em cada suíte Python:
548 descobertos, 464 aprovados, 84 ignorados,
zero erros/falhas. Os ignorados dependem do Guile ausente e não contam como sucesso.

Os 93 hashes de código coincidem antes/depois das duas execuções. Há 20 novos testes
Python executados, 14 novos casos ERT (234 no total), sete novos casos HTTP nativos e
quatro asserções Scheme. Os testes Emacs/Guile não foram executados neste ambiente.
Também faltam fish, mpv e Cargo. Não há certificação de segurança ou promessa de que
todo recurso funciona ao vivo.

As correções preservam categorias seguras de falha de foto, permitem retry por contato,
removem somente o destaque global pertencente ao buffer atual, mantêm autoria explícita
do histórico sem data_json, corrigem JIDs de About e exigem confirmação do destinatário
no novo envio normal. Aceito não é entregue. Não há reenvio automático, mudança de
privacidade, ampliação de CDN, troca silenciosa de player ou alteração do init.

A suíte de pacote valida transações/rollback e integridade; não substitui auditoria
nativa. Falhas de desenvolvimento e bloqueios foram preservados. Consulte o relatório
em inglês para os detalhes e limites completos, os recibos de execução e as referências.
O instalador continua exigindo duas auditorias nativas completas antes da substituição.

Uma execução separada do instalador real, sem mocks da auditoria, terminou as duas
auditorias e recusou a instalação. Todos os 182 arquivos existentes da instalação
sintética permaneceram idênticos, sem backup de substituição ou tentativa de reinício.
As 12 verificações de pacote/transação passaram. O arquivo final é extraído novamente
para conferir checksums e igualdade com os 93 hashes auditados.
