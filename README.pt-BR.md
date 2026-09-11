# WhatsAppel

**Um cliente nativo de WhatsApp para Emacs, construído com Emacs Lisp, Guile, wuzapi/whatsmeow, workers Python e ferramentas pós-quânticas opcionais.**

Versão candidata atual: **3.2.0-rc17**.

O WhatsAppel foi criado para manter as conversas dentro do Emacs sem transformar o editor em um simples navegador. O projeto prioriza navegação responsiva, estados de entrega explícitos, mídia, dados de perfil com respeito à privacidade, atualização segura no GNU Guix e publicação reproduzível.

> **Status:** RC17 ainda é um release candidate. Aceitação pelo provedor não significa entrega ao destinatário; fotos/presença dependem do backend e da privacidade da conta; a integração com Pale continua experimental/não verificada.

## Capturas de tela

As imagens abaixo vêm da interface nativa do Emacs. Em duas capturas de conversa foi removido **somente o rodapé/modeline** que continha um identificador local; as demais imagens foram incluídas sem alteração.

### Lista de contatos e workspace

![Lista de contatos do WhatsAppel](docs/screenshots/whatsappel-root.png)

### Envio aceito e controles de entrega

![Envio aceito no WhatsAppel](docs/screenshots/whatsappel-accepted.png)

### Configurações do workspace

![Configurações do WhatsAppel](docs/screenshots/whatsappel-settings.png)

### Visualização de imagens

![Imagem exibida no WhatsAppel](docs/screenshots/whatsappel-image-view.png)

### Mídia dentro da conversa

![Mídia em uma conversa](docs/screenshots/whatsappel-media.png)

Notas das capturas: [docs/SCREENSHOTS.pt-BR.md](docs/SCREENSHOTS.pt-BR.md).

## Principais recursos

- **Interface nativa no Emacs** com lista de conversas, buffers de chat, mouse e atalhos.
- **Abertura responsiva das conversas**, adiando histórico/mídia pesada quando possível.
- **Estados de envio claros**: pendente, aceito pelo provedor, entregue, lido, rejeitado e não confirmado.
- **Preservação de identidade do destinatário** para telefone, LID e grupos.
- **Imagens e multimídia**, GIFs limitados, gravação de voz, anexos e reprodução explícita.
- **Fotos de perfil e presença** com caches limitados e fallback compatível com privacidade.
- **Diagnóstico de entrega** para bridge, provedor, callback e assinaturas de eventos.
- **Fluxos opcionais de criptografia/PQ** com `pqenv`.
- **Integração amigável com GNU Guix**, usando Fish e sem exigir `sudo` ou `guix pull` no update normal.
- **Updates protegidos** por hashes, backups privados, rollback e publicação sem force-push.

## Arquitetura

```text
Cliente Emacs Lisp
       │
       ├── Workers Python ── leitura/envio/mídia/perfil
       │
       └── Bridge Guile ──── HTTP autenticado em loopback
                              │
                              └── wuzapi / whatsmeow
                                      │
                                      └── WhatsApp
```

## Atualização no GNU Guix

A partir de um bundle de release extraído:

```fish
fish scripts/update-and-activate.fish "$HOME/whatsappel" --restart-local
```

O fluxo executa as auditorias obrigatórias antes de substituir arquivos gerenciados, preserva `.env`, sessões, init e dados PQ independentes e recusa alterações locais desconhecidas.

Após um update bem-sucedido, reinicie totalmente o Emacs — inclusive o daemon, quando houver — para carregar o Lisp novo.

## Uso diário

A própria interface fornece ações para pesquisar/trocar conversas, criar chats, atualizar, enviar texto/arquivos, anexar mídia, gravar voz, repetir imagens que falharam e consultar diagnóstico de conexão/entrega.

O WhatsAppel não repete automaticamente um envio incerto, evitando duplicatas quando o provedor pode ter aceitado a mensagem antes de um timeout.

## Mídia

Imagens estáticas são exibidas no Emacs quando suportadas. GIFs usam limites explícitos. Áudio usa o player local configurado. O backend de vídeo pode ser escolhido nas configurações; **mpv é o caminho estabelecido e Pale continua experimental/não verificado**.

## Presença e perfil

O projeto não inventa estados remotos. “Online”, “offline”, “último acesso” e atividade dependem de eventos suportados, configuração do backend e privacidade da outra conta.

## Segurança

O projeto aplica autenticação na bridge, operação local por padrão, limites/deadlines nos workers, verificações de destino na mídia, confirmação antes de reparos potencialmente disruptivos e updates ancorados em hashes. Isso não equivale a uma certificação independente nem a um sandbox completo de codecs externos.

## Documentação

- [Correção de envio do RC17](docs/SEND-FAILURE-3.2.0-rc17.pt-BR.md)
- [Auditoria RC17](docs/AUDIT-3.2.0-rc17.md)
- [Capturas](docs/SCREENSHOTS.pt-BR.md)
- [English](README.md)

## Repositórios

- Codeberg: `codeberg.org/berkeley/whatsappel`
- GitHub: `github.com/cristiancmoises/whatsappel`
- Security Ops: `git.securityops.co/cristiancmoises/whatsappel` e `git.securityops.com.br/cristiancmoises/whatsappel`

## Licença

AGPL-3.0-only. Consulte [LICENSE](LICENSE).
