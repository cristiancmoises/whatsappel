# RC8: seleção de contatos sem trabalho pesado no clique

O compositor aparece antes da atualização agendada. Trocar de contato ou conta e
fechar o buffer invalida a abertura pendente. O clique muda apenas o destaque do
contato, sem reconstruir as linhas da lista.

Cada mensagem mostra inicialmente até 2.048 caracteres. **Read full text** abre
páginas locais de 8.192 caracteres; o conteúdo original continua preservado no registro
para leitura e cópia. Nomes e legendas têm limites próprios de visualização.

A inserção da conversa não inicia decodificadores de imagens. Prévias prontas são
reutilizadas; as restantes são decodificadas uma por ciclo, apenas na área visível.
O agendamento de rolagem não força redesenho e usa um temporizador de tempo real.
Isso não transforma os decodificadores nativos em um ambiente isolado.

Mensagens criptografadas sem texto já verificado agora exigem clicar em **Decrypt**.
O pqenv roda em um processo assíncrono por conversa, com prazo de dez segundos,
limites de entrada/saída e limpeza dos arquivos temporários privados de criptograma.
Assinatura, proteção contra repetição e --max-age não são removidos. Não há reenvio
nem nova tentativa automática. Um processo cancelado pode já ter atualizado o estado
de repetição do pqenv. O cache de texto fica associado à conta; o Org usa a mesma chave.

## Atualizar no GNU Guix

```fish
cd "$HOME/Downloads"
and sha256sum -c whatsappel-update-3.2.0-rc8.tar.gz.sha256
and tar -xzf whatsappel-update-3.2.0-rc8.tar.gz
and fish "$HOME/Downloads/whatsappel-update-3.2.0-rc8/scripts/update-guix.fish" "$HOME/whatsappel"
```

Não use sudo. A instalação só substitui arquivos reconhecidos após duas auditorias
completas bem-sucedidas. Configuração, sessões e PQ independente são preservados.
Não há guix pull, reconfigure, reinício de serviço ou push automático. RC7 para RC8
não modifica a ponte Guile. Reinicie a instância Emacs e abra ~/.local/bin/whatsappel.

Execute **M-x whatsapp-selection-diagnostics** para conferir a versão e o caminho
realmente carregados. O resumo não inclui mensagens, contatos, URL ou tokens.
Se continuar travando, ative **M-x toggle-debug-on-quit**, reproduza e pressione
**C-g**. Revise o backtrace antes de compartilhá-lo: ele pode conter dados privados.
Desative essa opção depois. Sem esse diagnóstico, a causa específica no ambiente
real ainda não está confirmada. Veja o relatório da auditoria para os limites dos testes.
