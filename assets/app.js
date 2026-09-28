(function () {
  const cfg = window.CONFIG || {};
  const COLUNAS = ["titulo", "categoria", "publico", "situacao", "estrategia", "materiais", "tempo", "autor", "foto"];
  let praticas = [];
  let categoriaAtiva = "Todas";

  const $ = (id) => document.getElementById(id);

  // One crayon color per category; new categories take the next free color.
  const CORES_FIXAS = {
    "leitura e escrita": "--c-ceu",
    "matematica": "--c-sol",
    "tdah e atencao": "--c-tangerina",
    "tea": "--c-lilas",
    "comportamento": "--c-coral",
    "deficiencia intelectual": "--c-menta",
    "altas habilidades": "--c-rosa",
    "ensino colaborativo": "--c-turquesa",
  };
  const PALETA = ["--c-ceu", "--c-sol", "--c-tangerina", "--c-lilas", "--c-coral", "--c-menta", "--c-rosa", "--c-turquesa"];
  const coresExtras = {};
  function corDa(categoria) {
    const chave = normalizar(categoria);
    if (CORES_FIXAS[chave]) return `var(${CORES_FIXAS[chave]})`;
    if (!coresExtras[chave]) coresExtras[chave] = PALETA[Object.keys(coresExtras).length % PALETA.length];
    return `var(${coresExtras[chave]})`;
  }

  // CSV parser that handles quotes, commas, and line breaks inside fields.
  function parseCSV(texto) {
    const linhas = [];
    let linha = [], campo = "", aspas = false;
    for (let i = 0; i < texto.length; i++) {
      const c = texto[i];
      if (aspas) {
        if (c === '"' && texto[i + 1] === '"') { campo += '"'; i++; }
        else if (c === '"') aspas = false;
        else campo += c;
      } else if (c === '"') aspas = true;
      else if (c === ",") { linha.push(campo); campo = ""; }
      else if (c === "\n" || c === "\r") {
        if (c === "\r" && texto[i + 1] === "\n") i++;
        linha.push(campo); linhas.push(linha); linha = []; campo = "";
      } else campo += c;
    }
    if (campo || linha.length) { linha.push(campo); linhas.push(linha); }
    return linhas;
  }

  // Header names accepted for each column. Matching is by prefix, so a
  // Google Forms question like "Título da prática" maps to "titulo".
  const APELIDOS = {
    titulo: ["titulo", "nomedapratica"],
    categoria: ["categoria"],
    publico: ["publico", "paraquem"],
    situacao: ["situacao", "qualasituacao", "oqueacontece"],
    estrategia: ["estrategia", "comofazer", "passo"],
    materiais: ["materia"],
    tempo: ["tempo"],
    autor: ["autor", "contribu", "seunome"],
    foto: ["foto", "imagem"],
  };

  function paraObjetos(linhas) {
    const cab = linhas.shift().map((h) => normalizar(h).replace(/[^a-z0-9]/g, ""));
    const indice = Object.fromEntries(COLUNAS.map((col) =>
      [col, cab.findIndex((h) => APELIDOS[col].some((a) => h.startsWith(a)))]));
    return linhas
      .map((l) => Object.fromEntries(COLUNAS.map((col) => [col, indice[col] < 0 ? "" : (l[indice[col]] || "").trim()])))
      .filter((p) => p.titulo);
  }

  function normalizar(s) {
    return (s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
  }

  function el(tag, attrs, ...filhos) {
    const n = document.createElement(tag);
    Object.entries(attrs || {}).forEach(([k, v]) => (k === "class" ? (n.className = v) : n.setAttribute(k, v)));
    filhos.flat().forEach((f) => f != null && n.append(f));
    return n;
  }

  function cartao(p) {
    const passos = p.estrategia.split(/\n+/).map((s) => s.trim()).filter(Boolean);
    return el("article", { class: "card", style: `--cor: ${corDa(p.categoria)}` },
      p.foto ? el("img", { class: "card-foto", src: p.foto, alt: p.titulo, loading: "lazy" }) : null,
      el("span", { class: "tag" }, p.categoria || "Geral"),
      el("h3", {}, p.titulo),
      p.publico ? el("p", { class: "publico" }, p.publico) : null,
      p.situacao ? el("p", { class: "situacao" }, el("b", {}, "a situação"), p.situacao) : null,
      el("details", {},
        el("summary", {}, "Ver estratégia"),
        el("ol", {}, passos.map((s) => el("li", {}, s))),
        el("p", { class: "meta" },
          p.materiais ? el("span", {}, el("b", {}, "Materiais: "), p.materiais) : null,
          p.tempo ? el("span", {}, el("b", {}, "Tempo: "), p.tempo) : null,
          p.autor ? el("span", {}, el("b", {}, "Por: "), p.autor) : null)
      )
    );
  }

  function renderFiltros() {
    const cats = ["Todas", ...new Set(praticas.map((p) => p.categoria).filter(Boolean))];
    $("filtros").replaceChildren(...cats.map((c) => {
      const attrs = { class: "chip", type: "button", "aria-pressed": String(c === categoriaAtiva) };
      if (c !== "Todas") attrs.style = `--cor: ${corDa(c)}`;
      const b = el("button", attrs, c);
      b.onclick = () => { categoriaAtiva = c; renderFiltros(); renderLista(); };
      return b;
    }));
  }

  // Common Portuguese words that say nothing about the situation.
  const PALAVRAS_VAZIAS = new Set(("a o as os um uma uns umas de da do das dos em na no nas nos por para pra com sem que " +
    "e ou se ele ela eles elas meu minha seu sua nao sim muito mais menos esta estao fica ficam tem ter ser sao " +
    "aluno aluna alunos crianca criancas filho filha consegue").split(" "));

  // Short word stem so "fica" finds "ficar" and "sentado" finds "sentar".
  const raiz = (palavra) => palavra.slice(0, Math.max(5, palavra.length - 2));

  // Everyday words teachers use, pointed at words the practices actually contain.
  const SINONIMOS = {
    bate: "agress", agride: "agress", agressivo: "agress", briga: "confronto", birra: "crise",
    grita: "gritos", chora: "choro", foge: "fuga", autista: "autismo", hiperativo: "tdah",
    agitado: "agitacao", desatento: "atencao", distraido: "atencao", superdotado: "superdotacao",
    ler: "leitura", escrever: "escrita", conta: "operacoes", contas: "operacoes", numeros: "matematica",
  };

  function termosDaBusca() {
    return normalizar($("busca").value)
      .split(/[^a-z0-9]+/)
      .filter((w) => (w.length >= 3 || SINONIMOS[w]) && !PALAVRAS_VAZIAS.has(w))
      .map((w) => raiz(SINONIMOS[w] || w));
  }

  function pontuacao(p, termos) {
    const palavras = normalizar(COLUNAS.map((c) => p[c]).join(" ")).split(/[^a-z0-9]+/);
    return termos.filter((t) => palavras.some((w) => w.startsWith(t))).length;
  }

  function renderLista() {
    const termos = termosDaBusca();
    let itens = praticas.filter((p) => categoriaAtiva === "Todas" || p.categoria === categoriaAtiva);
    if (termos.length) {
      itens = itens
        .map((p) => ({ p, n: pontuacao(p, termos) }))
        .filter((x) => x.n > 0)
        .sort((a, b) => b.n - a.n)
        .map((x) => x.p);
    }
    $("lista").replaceChildren(...itens.map(cartao));
    $("vazio").hidden = itens.length > 0;
    const total = itens.length === 1 ? "1 prática" : itens.length + " práticas";
    $("contagem").textContent = total;

    const buscando = $("busca").value.trim() !== "";
    $("resultado-busca").hidden = !buscando;
    $("resultado-texto").textContent = itens.length
      ? (itens.length === 1 ? "1 prática encontrada" : itens.length + " práticas encontradas")
      : "Nenhuma prática encontrada. Tente outras palavras.";
    $("ver-resultados").hidden = itens.length === 0;
  }

  function irParaResultados() {
    $("busca").blur();
    $("titulo-praticas").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  async function carregar() {
    const fontes = [cfg.planilhaCSV, "data/praticas.csv"].filter(Boolean);
    for (const url of fontes) {
      try {
        const r = await fetch(url, { cache: "no-store" });
        if (!r.ok) continue;
        const lista = paraObjetos(parseCSV(await r.text()));
        if (lista.length) return lista;
      } catch (e) { /* try the next source */ }
    }
    return [];
  }

  if (cfg.proposito) {
    // Text between *asterisks* gets a highlighter mark.
    $("proposito-texto").replaceChildren(...cfg.proposito.split("*").map((t, i) => (i % 2 ? el("mark", {}, t) : t)));
    $("proposito").hidden = false;
  }

  const boasVindas = cfg.boasVindas || [];
  if (boasVindas.length) {
    const [saudacao, ...paragrafos] = boasVindas;
    $("boas-vindas-texto").replaceChildren(
      el("h2", {}, saudacao),
      ...paragrafos.map((t) => el("p", {}, t)));
    $("boas-vindas").hidden = false;
  }

  const galeria = cfg.galeria || [];
  if (galeria.length) {
    $("galeria").replaceChildren(...galeria.map((f) =>
      el("figure", {},
        el("img", { src: f.arquivo, alt: f.legenda || "", loading: "lazy" }),
        f.legenda ? el("figcaption", {}, f.legenda) : null)));
    $("na-pratica").hidden = false;
  }
  if (cfg.formularioSugestao) { $("link-form").href = cfg.formularioSugestao; $("sugerir").hidden = false; }
  if (cfg.instagram) {
    $("link-insta").href = cfg.instagram;
    $("link-insta").textContent = "Siga no Instagram";
    $("link-insta").hidden = false;
  }
  $("busca").addEventListener("input", renderLista);
  $("form-busca").addEventListener("submit", (e) => { e.preventDefault(); renderLista(); irParaResultados(); });
  $("ver-resultados").addEventListener("click", irParaResultados);

  carregar().then((lista) => { praticas = lista; renderFiltros(); renderLista(); });
})();
