# Práticas Inclusivas

Banco de ideias e práticas pedagógicas para apoiar crianças com dificuldades de aprendizagem, transtornos de comportamento e deficiências.

**Custo:** zero. Paga-se só o domínio (opcional).

| Parte | Ferramenta | Custo |
|---|---|---|
| Hospedagem | GitHub Pages | Grátis |
| Cadastro de práticas | Google Forms | Grátis |
| Onde as práticas ficam guardadas | Planilha de respostas do Forms | Grátis |
| Endereço próprio | Domínio na Hostinger | Só o domínio |

## Como a organizadora atualiza o site

- **Adicionar uma prática:** abrir o formulário (um link salvo no celular), responder as perguntas e tocar em **Enviar**. Em poucos minutos a prática aparece no site.
- **Corrigir ou apagar:** abrir a planilha de respostas e mudar ou apagar a linha.

Ninguém precisa mexer em código. Enquanto o formulário não estiver ligado, o site mostra as 12 práticas de `data/praticas.csv`.

## 1. Publicar o site (GitHub Pages)

1. No GitHub, abra o repositório e vá em **Settings → Pages**.
2. Em *Source*, escolha **Deploy from a branch**, selecione a branch onde está o site e a pasta `/ (root)`, e clique em **Save**.
3. Em 1 a 2 minutos o site estará em `https://andyyyyyand.github.io/ando/`.

> No plano gratuito do GitHub, o Pages só funciona com repositório **público**.

## 2. Criar o formulário de cadastro (uma vez)

1. Em forms.google.com, crie um formulário com estas perguntas (os nomes precisam começar assim):

   | Pergunta | Tipo |
   |---|---|
   | Título da prática | Resposta curta |
   | Categoria | Lista suspensa (TEA, TDAH e atenção, Comportamento, Leitura e escrita, Matemática, Deficiência intelectual, Altas habilidades, Ensino colaborativo) |
   | Para quem é | Resposta curta |
   | Situação | Parágrafo |
   | Estratégia (um passo por linha) | Parágrafo |
   | Materiais | Resposta curta |
   | Tempo | Resposta curta |

2. Na aba **Respostas**, clique em **Vincular ao Planilhas** para criar a planilha de respostas.
3. Na planilha, cole abaixo das respostas as 12 práticas de exemplo de `data/praticas.csv`, se quiser mantê-las.
4. Na planilha, vá em **Arquivo → Compartilhar → Publicar na Web**, escolha a aba de respostas e o formato **CSV**, e clique em **Publicar**.
5. Copie o link e cole em `config.js`, no campo `planilhaCSV`.
6. Mande para a organizadora o link do formulário (para cadastrar) e compartilhe a planilha com ela como **Editor** (para corrigir).

O site aceita tanto os nomes do formulário quanto os nomes curtos (`titulo`, `categoria`, `publico`, `situacao`, `estrategia`, `materiais`, `tempo`, `autor`, `foto`). Colunas extras, como a data e hora do Forms, são ignoradas. Uma categoria nova vira um filtro com cor própria automaticamente.

## 3. Sugestões de outros professores (opcional)

Crie um segundo formulário, público, e cole o link no campo `formularioSugestao` do `config.js`. Aparece um botão "Sugerir uma prática" no site. As respostas vão para outra planilha; a organizadora revisa e cadastra as boas no formulário principal.

## Planilha em uso

O site lê esta planilha: https://docs.google.com/spreadsheets/d/1BKKcSiljjIs0mUsYnJ783i5yCSSOxDtP4Izew8MqCTI/edit

Ela precisa estar compartilhada como **Qualquer pessoa com o link → Leitor**. As colunas são: Título da prática, Categoria, Para quem é, Situação, Estratégia (um passo por linha), Materiais, Tempo e Foto (link, opcional).

## Textos do site

Em `config.js`:
- `proposito`: frase em destaque. Trechos entre `*asteriscos*` ganham marca-texto.
- `boasVindas`: mensagem de boas-vindas. Cada item é um parágrafo, e o primeiro vira o título.
- `instagram`: link do perfil.

## Fotos

| Onde | Campo | Para quê |
|---|---|---|
| "Na prática" | `galeria` em `config.js` | Registros do trabalho em sala, com legenda. A seção só aparece quando há fotos |
| Cartão da prática | coluna `foto` da planilha | Imagem do material ou da atividade |

Use fotos em JPG com até ~300 KB cada, na pasta `fotos/`.

> **Fotos com crianças:** só publique com autorização por escrito dos responsáveis (ECA e LGPD). Na dúvida, prefira fotos do material, de mãos trabalhando ou tiradas de costas, sem rosto e sem nome ou uniforme identificável.

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

4. No GitHub, em **Settings → Pages → Custom domain**, digite o domínio e salve.
5. Quando o DNS propagar (de alguns minutos a 24 h), marque **Enforce HTTPS**.

## Estrutura

```
index.html        página
config.js         textos e links (planilha, formulário, Instagram)
assets/app.js     carrega a planilha, busca e filtros
assets/style.css  visual (claro e escuro)
data/praticas.csv práticas de exemplo
```
