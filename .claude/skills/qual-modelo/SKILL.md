---
name: qual-modelo
description: Recomenda visualmente qual modelo Claude (Fable, Opus, Sonnet, Haiku) usar ao começar um projeto novo. Use quando o usuário disser "projeto novo", "qual versão/modelo usar", "qual Claude usar" ou invocar /qual-modelo.
---

# Qual modelo usar

Objetivo: dar ao usuário uma recomendação **visual e objetiva** do modelo Claude ideal para o projeto.

## Passos

1. **Diagnóstico.** Se o pedido do usuário já descreve o projeto, infira as respostas. Senão, faça UMA chamada de AskUserQuestion com estas 3 perguntas:
   - Tipo de projeto: site/landing simples · app/sistema com backend · automação/scripts · dados/análise · agentes/IA · outro
   - Complexidade: baixa (poucos arquivos) · média · alta (arquitetura, muitas integrações, código crítico)
   - Prioridade: velocidade/custo · equilíbrio · máxima qualidade

2. **Escolha** com a matriz abaixo (o modelo principal + um alternativo + quando trocar):

| Perfil | Principal | Alternativo |
|---|---|---|
| Tarefas simples, repetitivas, alto volume, custo baixo | **Haiku 4.5** (`claude-haiku-4-5-20251001`) | Sonnet 5.5 |
| Maioria dos projetos: sites, apps, scripts, dia a dia | **Sonnet 5.5** (`claude-sonnet-5-5`) | Opus 5.5 |
| Arquitetura, refatoração grande, bugs difíceis, código crítico | **Opus 5.5** (`claude-opus-5-5`) | Fable 5.1 |
| Problemas mais difíceis, pesquisa longa, agentes autônomos complexos | **Fable 5.1** (`claude-fable-5-1`) | Opus 5.5 |

   Regra prática: comece no modelo do meio (Sonnet). Suba para Opus/Fable quando travar em raciocínio ou arquitetura; desça para Haiku em subtarefas simples e em volume.

3. **Visual.** Copie `template.html` (nesta pasta) para o scratchpad, substitua os placeholders `{{...}}` (projeto, modelo principal, alternativo, ID do modelo, 3 motivos, "quando trocar", comando `/model`) e publique com a ferramenta Artifact (ícone `chart`). Carregue antes a skill `artifact-design`.

4. **Resposta no chat:** 2 linhas — modelo recomendado + link do artefato. Nada além disso.

## Notas
- Os IDs e modelos acima refletem o que o ambiente lista como mais recentes; se o usuário citar um modelo mais novo, priorize-o e atualize esta tabela.
- Para trocar o modelo: `/model` no Claude Code, ou o seletor de modelo no app.
