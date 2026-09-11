# RC17 — auditoria executada e limites

A correção verifica o tipo do corpo da resposta antes de usar `assoc` para obter
a mensagem de erro. O teste original recebe `(200 . :invalid-json)`. No RC16, o
formatador tentava tratar o símbolo como uma lista. A correção não aceita a resposta
inválida, não apaga o rascunho/resposta citada e não reenvia automaticamente.
O teste original permanece idêntico. O traceback nativo completo não foi fornecido;
o diagnóstico se baseia no código exato e no nome da regressão informado.

As duas auditorias completas retornaram 1: 6 PASS, 1 PARTIAL,
21 BLOCKED. Cada execução Python: 548 descobertos,
464 aprovados, 84 ignorados por falta de Guile, zero erros/falhas.
Os 93 hashes de código coincidem antes/depois e entre execuções.
244 testes ERT são fornecidos, incluindo 10 novos; NÃO foram executados aqui.
Emacs, Guile, fish, mpv e Cargo estão ausentes. A tentativa de obter o runtime
Debian não conseguiu transferir o pacote. A validação estrutural não substitui
execução nativa. Consulte os relatórios integrais e o documento em inglês.

Testes separados do pacote verificam atualização/rollback e preservação de dados;
eles não comprovam instalação nativa. O atualizador real mantém duas auditorias
completas antes de substituir arquivos; falhas impedem o reinício. Nada foi
instalado na máquina do usuário, enviado ao WhatsApp ou publicado nos remotos.
O comportamento da bridge e dos workers é preservado; versões foram atualizadas.
Fotos, entrega real, presença, gráficos e Pale continuam sujeitos à validação real.
Não reenvie tentativas incertas. Conserve o backup e o comando exato de rollback.
