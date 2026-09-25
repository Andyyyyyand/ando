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

  $("autora").textContent = cfg.nomeAutora || "";
  if (cfg.formularioSugestao) { $("link-form").href = cfg.formularioSugestao; $("sugerir").hidden = false; }
  if (cfg.instagram) { $("link-insta").href = cfg.instagram; $("link-insta").hidden = false; }
  $("busca").addEventListener("input", renderLista);

  carregar().then((lista) => { praticas = lista; renderFiltros(); renderLista(); });
})();
