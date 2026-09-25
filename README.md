# Práticas Inclusivas

Banco de ideias e práticas pedagógicas para apoiar crianças com dificuldades de aprendizagem, transtornos de comportamento e deficiências. Organizado por Fabiana Karina.

**Custo:** zero. Paga-se só o domínio (opcional).

| Parte | Ferramenta | Custo |
|---|---|---|
| Hospedagem | GitHub Pages | Grátis |
| Conteúdo | Planilha do Google | Grátis |
| Sugestões de professores | Google Forms (opcional) | Grátis |
| Endereço próprio | Domínio na Hostinger | Só o domínio |

## Como funciona

O site lê as práticas de uma **planilha do Google**. A Fabiana adiciona ou edita linhas na planilha e o site se atualiza sozinho em poucos minutos. Ela não precisa mexer em código.

Enquanto a planilha não estiver configurada, o site usa `data/praticas.csv`, que já vem com 12 práticas de exemplo.

## 1. Publicar o site (GitHub Pages)

1. No GitHub, abra o repositório e vá em **Settings → Pages**.
2. Em *Source*, escolha **Deploy from a branch**, selecione a branch onde está o site (hoje, `claude/jesse-contexto-sugestoes-t0tqb4`; se depois juntar na `main`, troque para `main`) e a pasta `/ (root)`, e clique em **Save**.
3. Em 1 a 2 minutos o site estará em `https://andyyyyyand.github.io/ando/`.

> No plano gratuito do GitHub, o Pages só funciona com repositório **público**.

## 2. Conectar a planilha

1. Crie uma planilha no Google Sheets.
2. Vá em **Arquivo → Importar** e envie o arquivo `data/praticas.csv`. Assim a planilha já nasce com as colunas certas e os 12 exemplos.
3. Vá em **Arquivo → Compartilhar → Publicar na Web**, escolha a aba e o formato **Valores separados por vírgula (.csv)**, e clique em **Publicar**.
4. Copie o link gerado e cole em `config.js`, no campo `planilhaCSV`.

### Colunas da planilha

A primeira linha tem que manter exatamente estes nomes:

| Coluna | O que escrever |
|---|---|
| `titulo` | Nome curto da prática |
| `categoria` | Vira um filtro no site, ex.: `TEA`, `TDAH e atenção` |
| `publico` | Para quem é, ex.: `Autismo (TEA)` |
| `situacao` | O problema que o professor enfrenta |
| `estrategia` | Um passo por linha (dentro da célula, use **Alt+Enter** para quebrar a linha) |
| `materiais` | O que precisa |
| `tempo` | Tempo de preparo ou aplicação |
| `autor` | Quem contribuiu |

## 3. Sugestões de professores (opcional)

Crie um Google Forms com as mesmas perguntas das colunas e cole o link no campo `formularioSugestao` do `config.js`. Aparece um botão "Sugerir uma prática" no site. As respostas caem numa planilha; a Fabiana revisa e copia as boas para a planilha principal.

## 4. Domínio próprio (Hostinger)

1. Na Hostinger, abra **Domínios → (seu domínio) → DNS / Nameservers**.
2. Apague os registros `A` e `CNAME` que já existirem para `@` e `www`.
3. Crie estes registros:

   | Tipo | Nome | Aponta para |
   |---|---|---|
   | A | @ | 185.199.108.153 |
   | A | @ | 185.199.109.153 |
   | A | @ | 185.199.110.153 |
   | A | @ | 185.199.111.153 |
   | CNAME | www | andyyyyyand.github.io |

4. No GitHub, em **Settings → Pages → Custom domain**, digite o domínio (ex.: `praticasinclusivas.com.br`) e salve.
5. Quando o DNS propagar (de alguns minutos a 24 h), marque **Enforce HTTPS**.

## Estrutura

```
index.html        página
config.js         links configuráveis (planilha, formulário, Instagram)
assets/app.js     carrega a planilha, busca e filtros
assets/style.css  visual (claro e escuro)
data/praticas.csv práticas de exemplo e modelo da planilha
```
