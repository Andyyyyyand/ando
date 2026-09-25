(function () {
  const cfg = window.CONFIG || {};
  const COLUNAS = ["titulo", "categoria", "publico", "situacao", "estrategia", "materiais", "tempo", "autor"];
  let praticas = [];
  let categoriaAtiva = "Todas";

  const $ = (id) => document.getElementById(id);

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

  function paraObjetos(linhas) {
    if (!linhas.length) return [];
    linhas[0][0] = linhas[0][0].replace(/^\uFEFF/, "");
    const cab = linhas.shift().map((h) => normalizar(h).replace(/\s+/g, ""));
    return linhas
      .map((l) => Object.fromEntries(COLUNAS.map((col) => [col, (l[cab.indexOf(col)] || "").trim()])))
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
    return el("article", { class: "card" },
      el("span", { class: "tag" }, p.categoria || "Geral"),
      el("h3", {}, p.titulo),
      p.publico ? el("p", { class: "publico" }, p.publico) : null,
      p.situacao ? el("p", { class: "situacao" }, el("b", {}, "Situação: "), p.situacao) : null,
      el("details", {},
        el("summary", {}, "Ver estratégia"),
        el("ol", {}, passos.map((s) => el("li", {}, s))),
        p.materiais ? el("p", { class: "meta" }, "Materiais: " + p.materiais) : null,
        p.tempo ? el("p", { class: "meta" }, "Tempo: " + p.tempo) : null,
        p.autor ? el("p", { class: "meta" }, "Contribuição: " + p.autor) : null
      )
    );
  }

  function renderFiltros() {
    const cats = ["Todas", ...new Set(praticas.map((p) => p.categoria).filter(Boolean))];
    $("filtros").replaceChildren(...cats.map((c) => {
      const b = el("button", { class: "chip", type: "button", "aria-pressed": String(c === categoriaAtiva) }, c);
      b.onclick = () => { categoriaAtiva = c; renderFiltros(); renderLista(); };
      return b;
    }));
  }

  function renderLista() {
    const termo = normalizar($("busca").value.trim());
    const itens = praticas.filter((p) =>
      (categoriaAtiva === "Todas" || p.categoria === categoriaAtiva) &&
      (!termo || normalizar(COLUNAS.map((c) => p[c]).join(" ")).includes(termo))
    );
    $("lista").replaceChildren(...itens.map(cartao));
    $("vazio").hidden = itens.length > 0;
    $("contagem").textContent = itens.length === 1 ? "1 prática" : itens.length + " práticas";
  }

  // Accepts any Google Sheets link (edit, pubhtml or pub CSV) and returns a CSV URL.
  function urlCSV(url) {
    url = (url || "").trim();
    const pub = url.match(/docs\.google\.com\/spreadsheets\/d\/e\/([\w-]+)/);
    const doc = url.match(/docs\.google\.com\/spreadsheets\/d\/([\w-]+)/);
    const gid = (url.match(/[#&?]gid=(\d+)/) || [])[1];
    if (pub) return "https://docs.google.com/spreadsheets/d/e/" + pub[1] + "/pub?output=csv" + (gid ? "&gid=" + gid : "");
    if (doc) return "https://docs.google.com/spreadsheets/d/" + doc[1] + "/gviz/tq?tqx=out:csv" + (gid ? "&gid=" + gid : "");
    return url;
  }

  async function carregar() {
    const fontes = [urlCSV(cfg.planilhaCSV), "data/praticas.csv"].filter(Boolean);
    for (const url of fontes) {
      try {
        const r = await fetch(url, { cache: "no-store" });
        if (!r.ok) throw new Error("HTTP " + r.status);
        const lista = paraObjetos(parseCSV(await r.text()));
        if (lista.length) return lista;
        throw new Error("nenhuma linha com a coluna 'titulo'");
      } catch (e) {
        console.warn("Práticas Inclusivas: não foi possível ler " + url + " (" + e.message + ")");
      }
    }
    return null;
  }

  $("autora").textContent = cfg.nomeAutora || "";
  if (cfg.formularioSugestao) { $("link-form").href = cfg.formularioSugestao; $("sugerir").hidden = false; }
  if (cfg.instagram) { $("link-insta").href = cfg.instagram; $("link-insta").hidden = false; }
  $("busca").addEventListener("input", renderLista);

  $("contagem").textContent = "Carregando práticas…";
  carregar().then((lista) => {
    if (!lista) {
      $("contagem").textContent = "";
      $("vazio").textContent = "Não foi possível carregar as práticas agora. Recarregue a página em alguns instantes.";
      $("vazio").hidden = false;
      return;
    }
    praticas = lista; renderFiltros(); renderLista();
  });
})();
