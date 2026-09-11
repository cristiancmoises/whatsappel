# Auditoria RC13

**Candidato; validação nativa e entrega real ainda pendentes.** Duas auditorias
completas em /usr/bin/python3 retornaram 1: 6 PASS, 1 PARTIAL e 20 BLOCKED.
Em cada execução: 466 testes Python encontrados, 389 aprovados, 77 pulados,
zero falhas/erros. Os 77 pulados exigem Guile. Emacs, Guile, fish, mpv e Cargo
não estão disponíveis neste ambiente. 88 hashes de código/build foram idênticos.

O relatório do usuário é do candidato RC11: 462 Python aprovados, apenas um teste
ERT antigo falhou. Seus 87 hashes coincidem exatamente com o RC11 retido. Esse
resultado não é auditoria RC13 nem prova de que o RC11 foi instalado. O novo teste
mantém seu identificador e valida o contrato atual /send + payload no worker.
Nenhum teste foi removido ou transformado em skip para passar.

O erro de destinatário foi identificado no código: a função retirava @lid e enviava
os dígitos como telefone. O bridge preserva @lid no histórico. RC13 mantém a
identidade completa e não infere vínculos nem reenvia mensagens antigas. Duas novas
regressões Python usam workers e HTTP locais reais; 34 testes do conjunto de entrega
passaram. Isso não executa a função Lisp nem confirma o celular do destinatário.

Foram fornecidos 210 testes ERT (17 novos) e dois novos testes Guile de armazenamento
LID/recibos. Não executados aqui. As notas locais de envio usam uma única sobreposição,
16 entradas/256 KiB, reconciliadas por ID próprio da conversa, nunca por texto. Não
são fila persistente nem comprovante de entrega. O tema global e init não são alterados.

Duas execuções iniciais em /opt/pyvenv/bin/python3 falharam em dois testes de tempo
existentes: a inicialização do interpretador levou aproximadamente 1,9–2 segundos.
Uma medição separada registrou aproximadamente 0,05 segundo com /usr/bin/python3.
O código e o limite de 2,5 segundos dos testes não foram relaxados. As duas execuções
com o interpretador de sistema passaram nesses testes. Logs das falhas e amostras
continuam no pacote. Isso não é ganho de desempenho do WhatsAppel. Uma execução
inicial interrompida pelo timeout da ferramenta também não foi contada como sucesso.

Os testes de pacote/reversão são separados da validação nativa. Consulte
package-validation.json e o relatório inglês completo. O instalador exige duas
auditorias completas aprovadas, preserva dados e recusa alterações desconhecidas.
Checksum não é assinatura independente. Reative bridge e Emacs somente após sucesso;
verifique o RC13 carregado e valide uma mensagem intencional com destinatário que
concorde em confirmar. Nenhum envio real, push, deploy, reset, pareamento ou alteração
de privacidade ocorreu. Pale permanece incompleto. Linhas gráficas, desempenho de
GUI, fotos reais e entrega não foram confirmados neste ambiente.
