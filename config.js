// Configuração do site. Edite só os textos entre aspas.
window.CONFIG = {
  // Link da planilha de respostas do Google Forms, publicada como CSV
  // (Arquivo > Compartilhar > Publicar na Web > CSV).
  // Enquanto estiver vazio, o site usa o arquivo data/praticas.csv.
  planilhaCSV: "https://docs.google.com/spreadsheets/d/1BKKcSiljjIs0mUsYnJ783i5yCSSOxDtP4Izew8MqCTI/gviz/tq?tqx=out:csv",

  // Link público de um formulário para outros professores sugerirem práticas (opcional).
  formularioSugestao: "",

  // Instagram do projeto. Enquanto estiver vazio, o rodapé mostra "Instagram: em breve!".
  instagram: "",

  // Atalhos que aparecem embaixo da busca: [texto do botão, palavras buscadas].
  atalhosBusca: [
    ["Não fica sentado", "fica sentado"],
    ["Crises e choro", "crise choro"],
    ["Dificuldade para ler", "leitura"],
    ["Agressividade", "agressivo"],
    ["Não termina a tarefa", "termina"],
    ["Autismo", "autismo"],
  ],


  // Frase de propósito, em destaque. Trechos entre *asteriscos* ganham marca-texto.
  proposito: "Meu propósito é encontrar caminhos para que cada criança possa aprender, porque *todos são capazes de aprender* quando encontram o caminho certo!",

  // Mensagem de boas-vindas (cada item é um parágrafo).
  boasVindas: [
    "Seja muito bem-vindo a este espaço!",
    "Sou educadora apaixonada pela aprendizagem e pelo universo das crianças. Este espaço foi criado para compartilhar atividades pedagógicas, ideias, estratégias e materiais educativos pensados especialmente para tornar a aprendizagem mais significativa, prazerosa e acessível.",
    "Acredito que cada criança aprende de uma maneira e no seu próprio tempo. Por isso, meu olhar psicopedagógico busca valorizar as potencialidades de cada aluno, principalmente daqueles que apresentam dificuldades no processo de aprendizagem.",
    "Que possamos compartilhar ideias, experiências e possibilidades para tornar a educação cada vez mais inclusiva, afetiva e significativa!",
  ],

  // Galeria "Na prática": fotos do trabalho em sala (pasta fotos/).
  // Exemplo: { arquivo: "fotos/rotina-visual.jpg", legenda: "Quadro de rotina com pictogramas" },
  galeria: [
  ],
};
