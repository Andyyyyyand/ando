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
  const estiloCor = (categoria) => `--cor: ${corDa(categoria)}; --cor-ink: ${corDa(categoria).replace(/\)$/, "-ink)")}`;
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

  // Wraps each letter in a span so titles can bounce letter by letter on hover.
  // Words stay unbroken, and screen readers get the plain text via aria-label.
  function letrasAnimadas(alvo) {
    if (!alvo || alvo.dataset.animado) return alvo;
    alvo.dataset.animado = "1";
    alvo.setAttribute("aria-label", alvo.textContent.trim());
    let n = 0;
    const percorrer = (no) => {
      [...no.childNodes].forEach((filho) => {
        if (filho.nodeType === Node.TEXT_NODE) {
          const frag = document.createDocumentFragment();
          filho.textContent.split(/(\s+)/).forEach((parte) => {
            if (!parte) return;
            if (/^\s+$/.test(parte)) { frag.append(parte); return; }
            const palavra = el("span", { class: "palavra", "aria-hidden": "true" });
            [...parte].forEach((ch) => palavra.append(el("span", { class: "letra", style: `--i: ${n++}` }, ch)));
            frag.append(palavra);
          });
          filho.replaceWith(frag);
        } else if (filho.nodeType === Node.ELEMENT_NODE && filho.tagName !== "svg") {
          percorrer(filho);
        }
      });
    };
    percorrer(alvo);
    return alvo;
  }

  // Touch-friendly animations: a tapped letter jumps, and titles wave when
  // they scroll into view or when their card is tapped.
  const semAnimacao = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function reiniciarClasse(alvo, classe) {
    alvo.classList.remove(classe);
    void alvo.offsetWidth;
    alvo.classList.add(classe);
  }

  function pularLetra(letra) {
    if (semAnimacao) return;
    letra.style.setProperty("--cor-pulo", `var(${PALETA[Math.floor(Math.random() * PALETA.length)]})`);
    reiniciarClasse(letra, "pula");
  }

  function ondaNoTitulo(titulo) {
    if (!semAnimacao && titulo) reiniciarClasse(titulo, "onda");
  }

  const observadorOnda = "IntersectionObserver" in window ? new IntersectionObserver((entradas) => {
    entradas.forEach((e) => {
      if (!e.isIntersecting) return;
      ondaNoTitulo(e.target);
      observadorOnda.unobserve(e.target);
    });
  }, { threshold: 0.8 }) : null;

  function observarOnda(titulo) {
    if (observadorOnda && !semAnimacao) observadorOnda.observe(titulo);
  }

  // ---- Public counters (read from GoatCounter; needs "Allow adding visitor counts on your website") ----
  const caminhoDaPratica = (titulo) => "/pratica/" + titulo;
  const CAMINHO_ACOMPANHAR = "/acompanhar";
  const cacheContagem = new Map();
  let filaContagem = Promise.resolve();

  // Reads one count, one request at a time. Resolves to a number, or null when unknown.
  function lerContagem(caminho) {
    if (!cfg.analytics) return Promise.resolve(null);
    if (cacheContagem.has(caminho)) return cacheContagem.get(caminho);
    const url = `https://${cfg.analytics}.goatcounter.com/counter/${encodeURIComponent(caminho)}.json`;
    const pedido = filaContagem = filaContagem.then(() =>
      fetch(url)
        // GoatCounter answers 404 with {"count":"0"} when nothing was counted yet, so read the body whatever the status.
        .then((r) => r.json().catch(() => null))
        .then((j) => (j && j.count != null ? parseInt(String(j.count).replace(/\D/g, ""), 10) || 0 : null))
        .catch(() => null));
    cacheContagem.set(caminho, pedido);
    return pedido;
  }

  const formatar = (n) => n.toLocaleString("pt-BR");

  // Shows the eye badge with a count. Stored on the element so a tap on the practice can add one live.
  function mostrarOlhos(olho, n) {
    olho.dataset.contagem = String(n);
    olho.querySelector("b").textContent = formatar(n);
    olho.querySelector(".olhos-texto").textContent = n === 1 ? " pessoa visualizou" : " pessoas visualizaram";
    olho.hidden = n === 0;
  }

  const observadorOlhos = cfg.analytics && "IntersectionObserver" in window ? new IntersectionObserver((entradas) => {
    entradas.forEach((e) => {
      if (!e.isIntersecting) return;
      observadorOlhos.unobserve(e.target);
      const olho = e.target.querySelector(".olhos");
      if (!olho) return;
      lerContagem(olho.dataset.caminho).then((n) => {
        if (n !== null) mostrarOlhos(olho, n);
      });
    });
  }, { rootMargin: "200px" }) : null;

  function iniciarAcompanhe() {
    if (!cfg.analytics) return;
    $("acompanhe").hidden = false;

    let jaAcompanha = false;
    try { jaAcompanha = localStorage.getItem("pi-acompanha") === "1"; } catch (e) { /* storage blocked */ }
    let totalAcompanham = null;

    const pintar = () => {
      const botao = $("btn-acompanhar");
      botao.setAttribute("aria-pressed", String(jaAcompanha));
      botao.disabled = jaAcompanha;
      $("rotulo-acompanhar").textContent = jaAcompanha ? "Você já acompanha ✓" : "Quero acompanhar";
      const mostrar = totalAcompanham !== null;
      $("bloco-acompanham").hidden = !mostrar;
      if (mostrar) {
        $("n-acompanham").textContent = formatar(totalAcompanham);
        $("leg-acompanham").textContent = totalAcompanham === 1 ? "pessoa acompanha" : "pessoas acompanham";
      }
    };
    pintar();

    $("btn-acompanhar").addEventListener("click", () => {
      if (jaAcompanha) return;
      jaAcompanha = true;
      try { localStorage.setItem("pi-acompanha", "1"); } catch (e) { /* storage blocked */ }
      registrar(CAMINHO_ACOMPANHAR, "Acompanhar o projeto", false);
      totalAcompanham = (totalAcompanham ?? 0) + 1;
      pintar();
    });

    lerContagem(CAMINHO_ACOMPANHAR).then((n) => { if (n !== null) { totalAcompanham = n + (jaAcompanha && n === 0 ? 1 : 0); pintar(); } });
    lerContagem(location.pathname).then((n) => {
      if (n !== null) { $("n-visitas").textContent = formatar(n); $("bloco-visitas").hidden = false; }
    });
  }

  // Eye badge: how many people opened this practice. Stays hidden until a real count above zero is known.
  function olhosDaPratica(titulo) {
    const span = el("span", { class: "olhos", hidden: "", title: "Pessoas que visualizaram esta prática", "data-caminho": caminhoDaPratica(titulo) });
    span.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M1.5 12S5.5 5 12 5s10.5 7 10.5 7-4 7-10.5 7S1.5 12 1.5 12z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><circle cx="12" cy="12" r="3.2" fill="currentColor"/></svg><b></b><span class="olhos-texto"></span>';
    return span;
  }

  function cartao(p) {
    const passos = p.estrategia.split(/\n+/).map((s) => s.trim()).filter(Boolean);
    return el("article", { class: "card", id: "pratica-" + praticas.indexOf(p), "data-titulo": p.titulo, style: estiloCor(p.categoria) },
      p.foto ? el("img", { class: "card-foto", src: p.foto, alt: p.titulo, loading: "lazy" }) : null,
      el("div", { class: "card-topo" },
        el("span", { class: "tag" }, p.categoria || "Geral"),
        olhosDaPratica(p.titulo)),
      letrasAnimadas(el("h3", {}, p.titulo)),
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
      if (c !== "Todas") attrs.style = estiloCor(c);
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

  function praticasEncontradas() {
    const termos = termosDaBusca();
    let itens = praticas.filter((p) => categoriaAtiva === "Todas" || p.categoria === categoriaAtiva);
    if (termos.length) {
      itens = itens
        .map((p) => ({ p, n: pontuacao(p, termos) }))
        .filter((x) => x.n > 0)
        .sort((a, b) => b.n - a.n)
        .map((x) => x.p);
    }
    return itens;
  }

  function renderLista() {
    const itens = praticasEncontradas();
    $("lista").replaceChildren(...itens.map(cartao));
    $("lista").querySelectorAll(".card h3").forEach(observarOnda);
    if (observadorOlhos) $("lista").querySelectorAll(".card").forEach((c) => observadorOlhos.observe(c));
    $("vazio").hidden = itens.length > 0;
    $("contagem").textContent = itens.length === 1 ? "1 prática" : itens.length + " práticas";
    renderSugestoes(itens);
  }

  // Live suggestions under the search box while the person types.
  function renderSugestoes(itens) {
    const digitado = $("busca").value.trim();
    const aberto = digitado.length >= 2 && document.activeElement && $("form-busca").parentNode.contains(document.activeElement);
    $("atalhos").hidden = digitado !== "";
    if (!aberto) { fecharSugestoes(); return; }

    const linhas = itens.slice(0, 5).map((p) => {
      const b = el("button", { type: "button", class: "sugestao", role: "option", style: estiloCor(p.categoria) },
        el("span", { class: "sugestao-titulo" }, p.titulo),
        el("span", { class: "sugestao-info" }, p.categoria + (p.situacao ? " · " + p.situacao : "")));
      b.addEventListener("click", () => abrirPratica(p));
      return b;
    });
    if (itens.length) {
      const todas = el("button", { type: "button", class: "sugestao-todas" },
        itens.length === 1 ? "Ver a prática encontrada ↓" : `Ver as ${itens.length} práticas encontradas ↓`);
      todas.addEventListener("click", irParaResultados);
      linhas.push(todas);
    } else {
      linhas.push(el("p", { class: "sugestao-vazia" }, "Nada encontrado com essas palavras. Tente descrever de outro jeito, ou use um dos atalhos abaixo."));
      $("atalhos").hidden = false;
    }
    $("sugestoes").replaceChildren(...linhas);
    $("sugestoes").hidden = false;
    $("busca").setAttribute("aria-expanded", "true");
  }

  function fecharSugestoes() {
    $("sugestoes").hidden = true;
    $("busca").setAttribute("aria-expanded", "false");
  }

  function irParaResultados() {
    fecharSugestoes();
    $("busca").blur();
    $("titulo-praticas").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function abrirPratica(p) {
    fecharSugestoes();
    $("busca").blur();
    const card = $("pratica-" + praticas.indexOf(p));
    if (!card) return;
    card.querySelector("details").open = true;
    card.scrollIntoView({ behavior: "smooth", block: "center" });
    card.classList.remove("destacado");
    void card.offsetWidth;
    card.classList.add("destacado");
  }

  function renderAtalhos() {
    const atalhos = cfg.atalhosBusca || [];
    if (!atalhos.length) { $("atalhos").remove(); return; }
    atalhos.forEach(([rotulo, busca]) => {
      const b = el("button", { type: "button", class: "atalho" }, rotulo);
      b.addEventListener("click", () => { $("busca").value = busca; renderLista(); irParaResultados(); });
      $("atalhos").append(b);
    });
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
      letrasAnimadas(el("h2", {}, saudacao)),
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
  } else {
    $("insta-em-breve").hidden = false;
  }

  document.querySelectorAll("h1, main h2").forEach((t) => { letrasAnimadas(t); observarOnda(t); });

  // Tap or drag a finger over a letter to make it jump (also works with a click).
  const letraSob = (e) => {
    const alvo = document.elementFromPoint(e.clientX, e.clientY);
    return alvo && alvo.classList.contains("letra") ? alvo : null;
  };
  let ultimaLetra = null;
  document.addEventListener("pointerdown", (e) => {
    const letra = letraSob(e);
    if (letra) { pularLetra(letra); ultimaLetra = letra; }
    const card = e.pointerType !== "mouse" && e.target.closest && e.target.closest(".card");
    if (card && !letra) ondaNoTitulo(card.querySelector("h3"));
  });
  document.addEventListener("pointermove", (e) => {
    if (e.pointerType === "mouse" || !e.pressure) return;
    const letra = letraSob(e);
    if (letra && letra !== ultimaLetra) { pularLetra(letra); ultimaLetra = letra; }
  });
  document.addEventListener("animationend", (e) => {
    if (e.target.classList.contains("pula")) e.target.classList.remove("pula");
    if (e.animationName === "onda" && e.target.classList.contains("letra")) {
      const titulo = e.target.closest(".onda");
      if (titulo && e.target === titulo.querySelector(".letra:last-of-type") ) titulo.classList.remove("onda");
    }
  });
  // Visit counter (GoatCounter: free, no cookies, no personal data). Off until cfg.analytics is set.
  // Counted: visits, which practice is opened, which category is chosen, and "Quero acompanhar" taps.
  // Search text is never sent.
  if (cfg.analytics) {
    const contador = document.createElement("script");
    contador.async = true;
    contador.dataset.goatcounter = `https://${cfg.analytics}.goatcounter.com/count`;
    contador.src = "https://gc.zgo.at/count.js";
    document.head.append(contador);
  }

  function registrar(caminho, titulo, evento) {
    if (cfg.analytics && window.goatcounter && window.goatcounter.count) {
      window.goatcounter.count({ path: caminho, title: titulo, event: !!evento });
    }
  }

  const praticasLidas = new Set();
  document.addEventListener("toggle", (e) => {
    const d = e.target;
    if (d.tagName !== "DETAILS" || !d.open) return;
    const card = d.closest(".card");
    const titulo = card && card.dataset.titulo;
    if (titulo && !praticasLidas.has(titulo)) {
      praticasLidas.add(titulo);
      registrar(caminhoDaPratica(titulo), titulo, false);
      // Counts this reader right away; the server total is read again on the next page load.
      const olho = card.querySelector(".olhos");
      if (olho) mostrarOlhos(olho, Number(olho.dataset.contagem || 0) + 1);
    }
  }, true);
  $("filtros").addEventListener("click", (e) => {
    const chip = e.target.closest(".chip");
    if (chip) registrar("categoria/" + chip.textContent, chip.textContent, true);
  });

  iniciarAcompanhe();

  // Day / night toggle. Starts from the phone's setting; a choice is remembered on this device.
  (function iniciarTema() {
    const raiz = document.documentElement, botao = $("tema");
    const escuroAgora = () => (raiz.dataset.theme ? raiz.dataset.theme === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches);
    const pintar = () => {
      const escuro = escuroAgora();
      botao.dataset.modo = escuro ? "dark" : "light";
      botao.setAttribute("aria-label", escuro ? "Mudar para o modo diurno" : "Mudar para o modo noturno");
    };
    botao.addEventListener("click", () => {
      const novo = escuroAgora() ? "light" : "dark";
      raiz.setAttribute("data-theme", novo);
      try { localStorage.setItem("pi-tema", novo); } catch (e) { /* storage blocked */ }
      pintar();
    });
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", pintar);
    new MutationObserver(pintar).observe(raiz, { attributes: true, attributeFilter: ["data-theme"] });
    pintar();
  })();

  renderAtalhos();
  $("busca").addEventListener("input", renderLista);
  $("busca").addEventListener("focus", () => renderSugestoes(praticasEncontradas()));
  $("busca").addEventListener("keydown", (e) => {
    if (e.key === "Escape") fecharSugestoes();
    if (e.key === "ArrowDown") { const primeira = $("sugestoes").querySelector("button"); if (primeira) { e.preventDefault(); primeira.focus(); } }
  });
  $("sugestoes").addEventListener("keydown", (e) => {
    const botoes = [...$("sugestoes").querySelectorAll("button")];
    const i = botoes.indexOf(document.activeElement);
    if (e.key === "ArrowDown" && i < botoes.length - 1) { e.preventDefault(); botoes[i + 1].focus(); }
    if (e.key === "ArrowUp") { e.preventDefault(); (i > 0 ? botoes[i - 1] : $("busca")).focus(); }
    if (e.key === "Escape") { fecharSugestoes(); $("busca").focus(); }
  });
  document.addEventListener("pointerdown", (e) => {
    if (!$("form-busca").parentNode.contains(e.target)) fecharSugestoes();
  });
  $("form-busca").addEventListener("submit", (e) => { e.preventDefault(); renderLista(); irParaResultados(); });

  carregar().then((lista) => { praticas = lista; renderFiltros(); renderLista(); });
})();
