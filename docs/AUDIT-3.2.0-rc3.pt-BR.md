# WhatsAppel 3.2.0-rc3 — auditoria executada

**Candidato a lançamento; validação nativa e em conta real incompleta.** Cada uma
das duas auditorias completas terminou com código **1**, com **4 verificações
aprovadas e 15 bloqueadas**. Não é uma auditoria integral aprovada.

Cada execução Python descobriu **139 testes: 115 aprovados, 24 ignorados, nenhuma
falha**. Os 24 ignorados dependem do Guile e continuam com verificações nativas
independentes bloqueadas. Há **91 casos ERT**, sendo **25 novos**, mas nenhum foi
executado aqui por ausência do Emacs. A análise estrutural de parênteses não
substitui o leitor, compilador ou interpretador Lisp.

Os 25 testes novos do auxiliar de leitura incluem 15 casos reais com subprocessos
e servidores HTTP locais e dez testes de validação. Cobrem bytes, Unicode, leitura
sem marcação, revisões, limites, enquadramento HTTP, respostas truncadas, JSON
inválido, ausência de redirecionamentos/reenvios, não uso de proxies de ambiente,
redação de erros e prazos para cabeçalhos atrasados/corpos enviados lentamente.
Não usaram uma conta real do WhatsApp. Mais seis testes verificam os hashes exatos
de compatibilidade e a recusa quando a fonte muda durante uma auditoria.

A suíte retida também exercita subprocessos de envio contra servidores locais,
bytes originais, FFmpeg real para GIF/MP4 e áudio Opus sintético, transações,
rollback e publicação em worktree local isolado. O caso de publicação simula
apenas a aprovação nativa para verificar isolamento; isso não representa um push
real nem aprovação do Emacs/Guile. As duas auditorias finais usaram Python 3.13.5
do sistema, com mapas de hashes idênticos antes/depois de ambas as execuções.

O pacote cumulativo foi preparado a partir das bases retidas 3.1, RC1 e RC2, com
77, 65 e 77 entradas de checksum conferidas. O HEAD atual da Codeberg não foi
verificado. Não há substituição do PQ independente, wuzapi, .env ou sessão. Da
RC2 para RC3 a ponte é idêntica; bases anteriores recebem a ponte RC2.

Consulte evidence/package-validation.json para resultados de compatibilidade,
aplicação/reversão do patch, preservação de estado e rollback. O log da instalação
real registra a recusa após testes nativos bloqueados, sem simular essa aprovação
e sem alterar arquivos instalados. A verificação final do arquivo compactado fica
separada para evitar hash autorreferente. Verificação de pacote não prova UI ou
entrega real de mensagens.

Permanecem bloqueados Emacs, Guile, fish, mpv e Rust/Cargo. Também não foram feitos
testes gráficos, captura física de microfone, reprodução em janela, pareamento,
sincronização/entrega real, ativação na VPS, pushes ou consulta atual de alertas de
dependências. Tentativas iniciais no ambiente virtual foram interrompidas; os logs
parciais não são classificados como aprovados. As duas execuções finais completas
estão identificadas separadamente.

Não foi medido ganho percentual de velocidade. O novo subprocesso possui custo de
inicialização e não é um sandbox. A marcação focada depende da API v2; pontes antigas
podem ignorar read=0. Não há novos sinalizadores PTT/GIF ou criptografia PQ de
anexos. Ainda existem caminhos administrativos e legados síncronos.

Nenhum deploy, push, branch, tag, release ou workflow foi criado nesta iteração.
O caminho de workflow recusado anteriormente não foi repetido. Execute a auditoria
nativa dupla antes da instalação; não há opção para ignorar verificações:

```fish
python3 scripts/update-package.py "$HOME/whatsappel" --audit-only --full-audit
```

O relatório inglês detalha cada verificação e as referências técnicas. O guia
RESPONSIVENESS-3.2.0-rc3.pt-BR.md explica uso, ativação e limites. Este é um relatório
de desenvolvimento, não uma certificação independente de segurança.
