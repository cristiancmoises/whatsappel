# Auditoria WhatsAppel 3.2.0-rc2

**Candidato, não uma versão integralmente validada.** As duas execuções da auditoria
completa terminaram com código 1: 3 verificações passaram e 15 ficaram bloqueadas
pela ausência de Emacs, Guile, fish, mpv e Cargo. Os mapas de hashes do código nas
duas execuções são idênticos.

Em cada execução Python: **108 testes encontrados, 84 passaram, 24 ignorados e
nenhuma falha**. Os 24 ignorados dependem de Guile. Foram fornecidos 66 testes ERT,
incluindo 20 novos, mas eles não foram executados neste ambiente. Os dez novos
testes HTTP nativos do bridge também ficaram bloqueados. Há 14 novos testes reais
HTTP do diagnóstico e quatro do lançador isolado, todos executados em Python.

O candidato implementa janela inicial de 60 mensagens, respostas condicionais por
revisão, resumos de conversas em cache, dois workers de mídia, lista compacta de
80 conversas por página, atualização incremental do histórico, preservação do
rascunho e atualização de prévias sem reconstruir o texto inteiro. Não há medição
de ganho de velocidade ou validação gráfica que permita garantir o resultado.

O diagnóstico não envia mensagens nem marca conversas como lidas; os relatórios
omitem tokens, nomes, textos, JIDs e URLs. O instalador verifica os hashes de cada
arquivo e executa duas passagens antes de modificar a instalação. Configuração,
sessões, pqenv e wuzapi não são substituídos. O bridge precisa ser reiniciado pelo
lançador/serviço já existente para ativar a API v2; copiar arquivos não atualiza
um processo em execução.

A base é o pacote rc1 preservado, cujos arquivos whatsapp.el e whatsappel.scm
coincidiram com os blobs consultados no GitHub. O HEAD atual do Codeberg e o
repositório completo não foram comprovados. Alterações locais desconhecidas são
recusadas, e o trabalho mais recente em pqenv permanece intocado.

Uma branch vazia `audit/chat-performance-rc2-20260909` foi criada no GitHub. A
criação do workflow de CI foi recusada na autorização e não foi repetida. Nenhum
código rc2 foi publicado, main não foi alterada, não houve deploy na VPS nem envio
real pelo WhatsApp.

Leia o relatório completo em `AUDIT-3.2.0-rc2.md` e os resultados individuais em
`evidence/audit-pass-1/`, `evidence/audit-pass-2/` e `package-validation.json`.
Interface gráfica, microfone físico, mpv, mensagens recebidas no telefone,
sincronização real e ativação na VPS continuam como critérios obrigatórios antes
de uso rotineiro. Esta revisão não é uma certificação de segurança independente.
