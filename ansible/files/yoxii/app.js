// Yoxii - multiplayer client. Draws and sends intents, decides nothing: the
// server owns the rules and marks the legal cells in every snapshot. One copy
// of the rules, so a doctored client is simply refused.
"use strict";

const SIZE = 7;
const LAYOUT = [
  "..###..",
  ".#####.",
  "#######",
  "#######",
  "#######",
  ".#####.",
  "..###..",
];
const ON_BOARD = new Set();
for (let r = 0; r < SIZE; r += 1) {
  for (let c = 0; c < SIZE; c += 1) {
    if (LAYOUT[r][c] === "#") ON_BOARD.add(`${r},${c}`);
  }
}

const DIRS = [
  [-1, -1], [-1, 0], [-1, 1],
  [0, -1], [0, 1],
  [1, -1], [1, 0], [1, 1],
];

const GLYPH = { 1: "O", 2: "II", 3: "Y", 4: "X" };
const PLAYERS = { W: "Blanc", R: "Rouge" };
const parse = (k) => k.split(",").map(Number);
const coord = (k) => {
  const [r, c] = parse(k);
  return `${String.fromCharCode(97 + c)}${SIZE - r}`;
};
const neighbours = (k) => {
  const [r, c] = parse(k);
  return DIRS.map(([dr, dc]) => `${r + dr},${c + dc}`).filter((n) => ON_BOARD.has(n));
};

// ------------------------------------------------------------------ State ---

let socket = null;
let mySide = null;
let roomId = null;
let peers = [];
let snap = null;
let selectedValue = null;
let retryDelay = 1000;

const $ = (id) => document.getElementById(id);
const boardEl = $("plateau");
const statusEl = $("status");
const hintEl = $("hint");
const historyEl = $("history");

// ---------------------------------------------------------------- Network ---

function connect() {
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  socket = new WebSocket(`${scheme}://${location.host}/ws`);

  socket.addEventListener("open", () => {
    retryDelay = 1000;
    hintEl.textContent = "";
  });

  socket.addEventListener("message", (event) => {
    const msg = JSON.parse(event.data);

    if (msg.type === "welcome") {
      mySide = msg.side;
      roomId = msg.room;
      document.body.dataset.side = mySide;
      $("room-id").textContent = msg.room;
      $("my-side-name").textContent = PLAYERS[mySide];
      $("my-dot").className = `dot dot--${mySide}`;
      $(`badge-${mySide}`).hidden = false;
      $(`badge-${mySide === "W" ? "R" : "W"}`).hidden = true;
    }

    if (msg.type === "state" || msg.type === "welcome") {
      if (msg.players) peers = msg.players;
      snap = msg.state;
      selectedValue = null;
      render();
      if (msg.peerLeft) {
        hintEl.textContent = "Votre adversaire a quitté la salle. La place est de nouveau libre.";
      }
    }

    if (msg.type === "error") {
      hintEl.textContent = msg.message;
    }
  });

  socket.addEventListener("close", () => {
    statusEl.textContent = "Connexion perdue.";
    hintEl.textContent = `Nouvelle tentative dans ${Math.round(retryDelay / 1000)} s…`;
    setTimeout(connect, retryDelay);
    // Backing off avoids hammering a server that is restarting.
    retryDelay = Math.min(retryDelay * 2, 15000);
  });
}

function send(payload) {
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}

// ------------------------------------------------------------------- View ---

function myTurn() {
  return snap && !snap.finished && snap.turn === mySide && peers.length === 2;
}

function render() {
  if (!snap) return;
  renderBoard();
  renderTrays();
  renderStatus();
  renderHistory();
  $("peer").textContent = peers.length === 2 ? "2 joueurs" : "en attente d'un adversaire";
  $("peer").classList.toggle("peer--waiting", peers.length !== 2);
  $("new-game").disabled = !snap.finished;
}

function renderBoard() {
  boardEl.replaceChildren();
  boardEl.style.setProperty("--size", SIZE);

  const legal = snap.legal;
  const moveTargets = new Map(
    myTurn() && snap.phase === "move" ? legal.moves.map((m) => [m.to, m]) : []
  );
  const placeTargets = new Set(
    myTurn() && snap.phase === "place" ? legal.places : []
  );
  const adjacent = new Set(neighbours(snap.totem));

  for (let r = 0; r < SIZE; r += 1) {
    for (let c = 0; c < SIZE; c += 1) {
      const k = `${r},${c}`;

      if (!ON_BOARD.has(k)) {
        const gap = document.createElement("div");
        gap.className = "cell cell--void";
        gap.setAttribute("aria-hidden", "true");
        boardEl.append(gap);
        continue;
      }

      const cell = document.createElement("button");
      cell.type = "button";
      cell.className = "cell";
      cell.setAttribute("role", "gridcell");

      const piece = snap.pieces[k];
      if (snap.totem === k) {
        cell.classList.add("cell--totem");
        cell.innerHTML = '<span class="totem" aria-hidden="true"></span>';
        cell.setAttribute("aria-label", `Totem en ${coord(k)}`);
      } else if (piece) {
        cell.classList.add("cell--piece", `cell--${piece.owner}`);
        cell.innerHTML = `<span class="piece" aria-hidden="true">${GLYPH[piece.value]}</span>`;
        cell.setAttribute(
          "aria-label",
          `${PLAYERS[piece.owner]} ${GLYPH[piece.value]}, ${piece.value} point${piece.value > 1 ? "s" : ""}, en ${coord(k)}`
        );
      } else {
        cell.setAttribute("aria-label", `Case vide ${coord(k)}`);
      }

      if (adjacent.has(k)) cell.classList.add("cell--adjacent");

      if (moveTargets.has(k)) {
        const m = moveTargets.get(k);
        cell.classList.add("cell--target");
        if (m.jumped > 0) cell.classList.add("cell--jump");
        cell.addEventListener("click", () => send({ type: "move", to: k }));
      } else if (placeTargets.has(k)) {
        cell.classList.add("cell--place");
        cell.addEventListener("click", () => {
          if (selectedValue === null) {
            hintEl.textContent = "Choisissez d'abord la valeur de la pièce.";
            return;
          }
          send({ type: "place", cell: k, value: selectedValue });
        });
      } else {
        cell.disabled = true;
      }

      boardEl.append(cell);
    }
  }
}

function renderTrays() {
  for (const player of ["W", "R"]) {
    const host = document.querySelector(`#tray-${player} .tray__pieces`);
    host.replaceChildren();

    for (const value of [1, 2, 3, 4]) {
      const left = snap.reserve[player][value];
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `chip chip--${player}`;
      btn.innerHTML =
        `<span class="chip__glyph" aria-hidden="true">${GLYPH[value]}</span>` +
        `<span class="chip__count">${left}</span>`;
      btn.setAttribute(
        "aria-label",
        `${GLYPH[value]}, ${value} point${value > 1 ? "s" : ""} — ${left} restante${left > 1 ? "s" : ""}`
      );

      const selectable =
        myTurn() && snap.phase === "place" && player === mySide && left > 0;
      btn.disabled = !selectable;

      if (selectedValue === value && selectable) {
        btn.classList.add("chip--selected");
        btn.setAttribute("aria-pressed", "true");
      } else {
        btn.setAttribute("aria-pressed", "false");
      }

      btn.addEventListener("click", () => {
        selectedValue = value;
        hintEl.textContent = "Cliquez une case surlignée pour poser la pièce.";
        render();
      });

      host.append(btn);
    }

    $(`score-${player}`).textContent =
      `${snap.score[player].points} pt${snap.score[player].points > 1 ? "s" : ""}`;
  }

  $("tray-W").classList.toggle("tray--active", snap.turn === "W" && !snap.finished);
  $("tray-R").classList.toggle("tray--active", snap.turn === "R" && !snap.finished);
}

function renderStatus() {
  if (snap.finished) {
    const o = snap.outcome;
    const other = o.winner === "W" ? "R" : "W";
    statusEl.textContent =
      o.winner === null
        ? "Partie nulle."
        : o.winner === mySide
          ? `Vous gagnez, ${o.score[o.winner].points} points contre ${o.score[other].points}.`
          : `${PLAYERS[o.winner]} gagne, ${o.score[o.winner].points} points contre ${o.score[other].points}.`;
    hintEl.textContent = "« Rejouer » relance une partie dans la même salle.";
    return;
  }

  if (peers.length < 2) {
    statusEl.textContent = "En attente d'un adversaire…";
    hintEl.textContent = `Partagez l'adresse : la prochaine personne rejoindra la salle ${roomId}.`;
    return;
  }

  if (!myTurn()) {
    statusEl.textContent = `Au tour de ${PLAYERS[snap.turn]}.`;
    hintEl.textContent = "";
    return;
  }

  if (snap.phase === "move") {
    const n = snap.legal.moves.length;
    statusEl.textContent = `À vous : déplacez le Totem (${n} possibilité${n > 1 ? "s" : ""}).`;
    hintEl.textContent = "Contour épais = saut par-dessus vos pièces.";
  } else {
    statusEl.textContent = "À vous : posez une pièce.";
    hintEl.textContent = snap.legal.anywhere
      ? "Toutes les cases autour du Totem sont prises : posez où vous voulez."
      : "Choisissez une valeur, puis une case autour du Totem.";
  }
}

function renderHistory() {
  historyEl.replaceChildren();
  for (const h of snap.history) {
    const li = document.createElement("li");
    li.className = `hist hist--${h.player}`;
    li.textContent = h.text;
    historyEl.append(li);
  }
  historyEl.scrollTop = historyEl.scrollHeight;
}

// ---------------------------------------------------------------- Controls ---

$("new-game").addEventListener("click", () => send({ type: "restart" }));

const rulesDialog = $("rules");
const rulesBtn = $("show-rules");
rulesBtn.addEventListener("click", () => {
  rulesDialog.showModal();
  rulesBtn.setAttribute("aria-expanded", "true");
});
rulesDialog.addEventListener("close", () => rulesBtn.setAttribute("aria-expanded", "false"));

// ---- Theme ----

const THEMES = ["auto", "light", "dark"];
const LABELS = { auto: "Thème : auto", light: "Thème : clair", dark: "Thème : sombre" };
const root = document.documentElement;
const themeBtn = $("theme-toggle");

function applyTheme(name) {
  root.setAttribute("data-theme", name);
  themeBtn.textContent = LABELS[name];
  try {
    localStorage.setItem("yoxii-theme", name);
  } catch {
    /* private browsing denies storage; the toggle still works for this visit */
  }
}

let storedTheme = null;
try {
  storedTheme = localStorage.getItem("yoxii-theme");
} catch {
  storedTheme = null;
}
applyTheme(THEMES.includes(storedTheme) ? storedTheme : "auto");

themeBtn.addEventListener("click", () => {
  applyTheme(THEMES[(THEMES.indexOf(root.getAttribute("data-theme")) + 1) % THEMES.length]);
});

connect();
