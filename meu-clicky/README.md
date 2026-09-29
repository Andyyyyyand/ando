# Meu Clicky

Assistente de voz que fica ao lado do cursor, vê sua tela, responde falando e aponta para o botão certo. Esta versão roda no seu Mac, sem assinatura.

Ele é baseado no [Clicky de código aberto do Farza](https://github.com/farzaa/clicky), que tem licença MIT. O README original está em [README-original-en.md](README-original-en.md).

## Como funciona

| Parte | Original (pago) | Meu Clicky |
|---|---|---|
| Entender sua voz | AssemblyAI | Reconhecimento de voz da Apple, no próprio Mac, em português |
| Cérebro | Claude, sempre | **Híbrido**: modelo local (Qwen3-VL 4B pelo Ollama) nas perguntas simples e Claude nas difíceis |
| Apontar na tela | Claude estima as coordenadas | Lista de botões lida do macOS, com posição exata. Se o botão não estiver na lista, usa coordenadas |
| Voz | ElevenLabs | Kokoro (mlx-audio), grátis, com voz da Apple como reserva |
| Agente | Nuvem do Clicky | Ações rápidas no Mac com o modelo local, e tarefas pesadas com o **Claude Code** (usa sua assinatura do Claude) |
| Servidor intermediário | Cloudflare Worker | Nenhum |
| Estatísticas de uso e e-mail | PostHog e FormSpark | Desligados |

### Quem responde cada pergunta (modo Auto)
1. **Pedido explícito:** "usa o claude" ou "pergunta difícil" vai para o Claude. "responde rápido" fica no Mac.
2. **Perguntas complexas vão para o Claude:** as que pedem para explicar, analisar código ou erros, resumir, comparar, escrever ou calcular, e as muito longas.
3. **O resto fica no Mac:** e mesmo assim, se o modelo local não tiver certeza, ele passa a pergunta para o Claude.
4. **Sem chave do Claude:** tudo roda no Mac.

No painel você escolhe **Auto**, **Local** ou **Claude** e vê quem respondeu a última pergunta.

### Agentes
Diga **"agente, ..."** segurando Control+Option. Exemplos:
- "agente, me lembra de ligar pro João amanhã às nove": cria um lembrete na hora, pelo modelo local
- "agente, marca reunião sexta às três da tarde": cria o evento no Calendário
- "agente, abre o Spotify"
- "agente, pesquisa os cinco melhores notebooks até cinco mil reais e salva um resumo": vai para o Claude Code, que trabalha em segundo plano

**Enquanto um agente trabalha:**
- Aparece um ponto no ícone da barra de menu.
- O painel mostra o andamento; clique na setinha para ver o log completo.
- Quando termina, o resultado é falado em voz alta e aparece uma notificação.

**Regras do agente pesado:**
- Trabalha dentro de `~/ClickyAgente`.
- Por padrão pode ler, escrever e pesquisar na web, mas **não** pode rodar comandos no Terminal. Para liberar, ligue "Agente pode usar o Terminal" em Configurações.

## Instalação (Mac com chip Apple)

### 1. Instalar os serviços locais
No Terminal, dentro da pasta do projeto:
```bash
bash scripts/instalar-meu-clicky.sh
```
O script instala:
- **Homebrew**, se ainda não tiver.
- **Ollama** com o modelo `qwen3-vl:4b-instruct` (~3,3 GB).
- **Servidor de voz Kokoro**, rodando em segundo plano na porta 8123.
- **Claude Code.**

Se nunca usou o Claude Code, rode `claude` no Terminal uma vez e faça login.

### 2. Compilar o app

**Só pelo Terminal (sem abrir o Xcode):**
```bash
bash scripts/compilar-e-abrir.sh
```
O script instala o Xcode pela App Store se faltar (para isso, você precisa estar logado na App Store), compila e coloca o app em `~/Applications/Meu Clicky.app`. A assinatura é local, então não precisa configurar Apple ID. **Limitação:** depois de cada nova compilação, o macOS pede as permissões de novo.

**Ou pelo Xcode:**
1. Instale o **Xcode 26** pela App Store.
2. Abra o projeto: `open leanring-buddy.xcodeproj`
3. Selecione o projeto **leanring-buddy** → aba **Signing & Capabilities** → em **Team**, escolha o seu Apple ID. Se não aparecer nenhum, clique em "Add Account…"; um Apple ID gratuito funciona.
4. Aperte **Cmd+R**.

O app aparece como um triângulo na barra de menu. Libere as quatro permissões que o painel pedir (Acessibilidade, Gravação de tela, Conteúdo da tela e Microfone) e clique em **Começar**.

### 3. (Opcional) Chave do Claude para perguntas difíceis
1. Crie uma chave em [platform.claude.com](https://platform.claude.com/) → API Keys. A API é cobrada por uso e à parte da assinatura do claude.ai.
2. No painel do Meu Clicky: **Configurações** → cole a chave → **Salvar**. Ela fica guardada no Keychain do macOS.

**Custo por pergunta difícil:** com print da tela e lista de botões, deve ficar em cerca de US$ 0,04 no Opus 5 e US$ 0,015 no Sonnet 5. Perguntas simples ficam no Mac e não custam nada.

## Uso de recursos (M2 Pro, 16 GB)

| Situação | Memória | Observação |
|---|---|---|
| Em espera | ~50 MB (app) + ~300 MB (servidor de voz) | Nenhuma IA carregada |
| Respondendo no Mac | + ~3,5 GB | O Ollama libera a memória após 5 min sem uso |
| Respondendo pelo Claude | quase nada | O processamento é nos servidores da Anthropic |

## Problemas comuns

| Sintoma | Solução |
|---|---|
| "não consegui falar com o modelo local" | `brew services start ollama` |
| Voz robótica em vez da Kokoro | Veja `~/.meu-clicky/logs/kokoro.err.log` e rode o script de instalação de novo |
| Não entende o que eu falo | Ajustes do Sistema → Teclado → Ditado: baixe o português (Brasil) |
| Agente diz que o Claude Code não está instalado | `curl -fsSL https://claude.ai/install.sh \| bash` e depois `claude` para fazer login |
| Lembretes, Calendário ou Notas não funcionam | Ajustes do Sistema → Privacidade e Segurança → Automação → libere o Clicky |
| Aponta no lugar errado em algum app | Alguns apps (jogos, canvas) não expõem os botões ao macOS, e aí ele usa coordenadas aproximadas. Use o modo Claude para mais precisão |

## Para trocar o modelo local
No Terminal, baixe o modelo: `ollama pull <modelo>`. Depois rode:
```bash
defaults write com.yourcompany.leanring-buddy hybridLocalVisionModelName "<modelo>"
```
Um modelo maior, como `qwen3-vl:8b-instruct`, responde melhor, mas usa ~6 GB de memória e é mais lento.
