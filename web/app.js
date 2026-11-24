// drgnwrrr in the browser. Every button submits a command line to the
// engine's Session, the same commands the CLI takes, so the log reads the
// same. Mithril (vendor/mithril.min.js, global `m`) draws the panel; map.js
// draws the map.
import { loadEngine } from './engine.js';
import { createMap } from './map.js';
import { ATLAS, SPRITES } from './atlas.js';

const m = window.m;
const SAVE_KEY = 'drgnwrrr.sav';
const PREFS_KEY = 'drgnwrrr.prefs';
const LOG_LINES = 300;

const params = new URLSearchParams(location.search);
const fixedSeed = params.has('seed') ? Number(params.get('seed')) >>> 0 : null;

// ---------- storage (every access may throw: private windows, blocked storage) ----------

const store = {
  get(key) {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(key, value);
      return true;
    } catch {
      return false;
    }
  },
};

const toBase64 = (bytes) => btoa(String.fromCharCode(...bytes));
const fromBase64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

/**
 * Anvil is drawn on an 8 px grid: size the grid buttons' text (--glyph in style.css) so each of
 * its pixels is a whole number of device pixels, as near 13px as that allows (13.33px at 3x,
 * 12px at 2x, 16px at 1x). Again whenever the density changes (zoom, another monitor).
 */
function snapGlyph() {
  const dpr = window.devicePixelRatio || 1;
  const glyph = (Math.max(1, Math.round((13 * dpr) / 8)) * 8) / dpr;
  document.documentElement.style.setProperty('--glyph', `${glyph}px`);
  matchMedia(`(resolution: ${dpr}dppx)`).addEventListener('change', snapGlyph, { once: true });
}
snapGlyph();

const prefs = Object.assign({ risk: 'balanced', stop: 50, fights: 10, grindAuto: false, grindStop: 40, assist: true, showLog: false, showCmd: false, showWhere: false, logSize: 0.2, panelW: 0, panelH: 0 }, JSON.parse(store.get(PREFS_KEY) || '{}'));
const savePrefs = () => store.set(PREFS_KEY, JSON.stringify(prefs));

/** A fresh game starts with auto-battle off in Grind; the other choices carry over. */
function newGame() {
  prefs.grindAuto = false;
  savePrefs();
  S.engine.newGame();
  refresh();
}

// ---------- state ----------

const S = {
  engine: null,
  view: null,
  log: [],
  /** The menu shown in place of the commands (see Menu), or null. */
  menu: null,
  /** The map tile last tapped: tapping it again while its route waits walks it. */
  tapped: null,
  danger: null,
  hover: null,
  lastGo: null,
  /** When the player last saw a fresh screen: the time until the next command is idle time. */
  shownAt: performance.now(),
  error: null,
};

function say(text, kind = 'out') {
  for (const line of text.replace(/\n$/, '').split('\n')) S.log.push({ text: line, kind, fresh: true });
  if (S.log.length > LOG_LINES) S.log.splice(0, S.log.length - LOG_LINES);
}

function refresh() {
  S.view = S.engine.view();
  map.draw(S.view);
  S.shownAt = performance.now();
}

function persist() {
  if (!S.engine.sramDirty()) return;
  if (!store.set(SAVE_KEY, toBase64(S.engine.saveData()))) say('  (The browser refused to store the save. Use More > Options > Export to keep it.)', 'warn');
}

/** Runs one command line, as if typed. */
function run(line, { echo = true } = {}) {
  for (const l of S.log) l.fresh = false;
  if (echo) say(`> ${line}`, 'cmd');
  const idle = fixedSeed === null ? performance.now() - S.shownAt : 500; // 500 ms = 30 frames, like --seed
  const out = S.engine.submit(line, idle);
  if (out) say(out);
  if (/^go\b/i.test(line)) S.lastGo = line;
  if (!/^(go \d+ \d+|y)\b/i.test(line)) S.tapped = null;
  persist();
  const before = S.view?.mode;
  refresh();
  if (S.view.mode !== 'command' || before !== 'command') S.menu = null;
  if (S.menu === 'danger') S.danger = S.engine.danger();
  m.redraw();
}

function goCommand(target) {
  return `go ${target} ${prefs.risk} stop=${prefs.stop}`;
}

/** Yes to a planned route, with the HP threshold as it stands now. */
const walkCommand = () => `y stop=${prefs.stop}`;

// ---------- map ----------

const map = createMap(document.getElementById('map'), () => S.engine, {
  onTap(t) {
    const g = S.view?.game;
    if (!g || !['command', 'confirm_route'].includes(S.view.mode)) return;
    if (t.x === g.x && t.y === g.y) return;
    // Next to you: just step there.
    const step = { '0,-1': 'n', '0,1': 's', '-1,0': 'w', '1,0': 'e' }[`${t.x - g.x},${t.y - g.y}`];
    if (step && S.view.mode === 'command') {
      S.tapped = null;
      run(step);
      return;
    }
    // Past a town's edge: walk out of it, as the NES does.
    if (t.off) {
      if (g.town && S.view.mode === 'command') {
        S.tapped = null;
        run('leave');
      }
      return;
    }
    const again = S.tapped && S.tapped.x === t.x && S.tapped.y === t.y && S.tapped.map === g.map;
    if (again && S.view.mode === 'confirm_route') {
      S.tapped = null;
      run(walkCommand());
      return;
    }
    S.tapped = { x: t.x, y: t.y, map: g.map };
    run(goCommand(`${t.x} ${t.y}`));
  },
  onHover(t) {
    S.hover = t && t.off ? (S.view?.game?.town ? { label: 'Leave town' } : null) : t;
    m.redraw();
  },
});

/** A sprite from the atlas (one of Kenney's Input Prompts), drawn at 2x. */
const prompt = (name) => m('span.prompt', {
  style: { backgroundPosition: `-${SPRITES[name][0] * 2}px -${SPRITES[name][1] * 2}px`, backgroundSize: `${ATLAS.width * 2}px ${ATLAS.height * 2}px` },
});

/** The buttons over the map. */
const MapControls = {
  view: () => S.view?.game ? m('div.mapctl', [
    m('button', { type: 'button', title: 'Zoom in', 'aria-label': 'Zoom in', onclick: map.zoomIn }, prompt('zoom_in')),
    m('button', { type: 'button', title: 'Zoom out', 'aria-label': 'Zoom out', onclick: map.zoomOut }, prompt('zoom_out')),
    m('button', { type: 'button', title: 'Whole map', 'aria-label': 'Whole map', onclick: map.overview }, prompt('overview')),
    m('button', { type: 'button', title: 'Back to the hero', 'aria-label': 'Back to the hero', onclick: map.recentre }, prompt('recentre')),
  ]) : null,
};

document.addEventListener('keydown', (ev) => {
  if (ev.target instanceof HTMLInputElement || ev.ctrlKey || ev.metaKey || ev.altKey) return;
  const mode = S.view?.mode;
  const dir = { ArrowUp: 'n', ArrowDown: 's', ArrowLeft: 'w', ArrowRight: 'e', w: 'n', s: 's', a: 'w', d: 'e' }[ev.key];
  if (dir && mode === 'command') {
    ev.preventDefault();
    run(dir);
  } else if (ev.key === 'Enter' && mode === 'confirm_route') {
    ev.preventDefault();
    run(walkCommand());
  } else if (ev.key === 'Escape') {
    if (mode === 'confirm_route') run('n');
    else if (S.menu) {
      back();
      m.redraw();
    }
  } else if (ev.key === '+' || ev.key === '=') {
    map.zoomIn();
  } else if (ev.key === '-') {
    map.zoomOut();
  } else if (ev.key === '0') {
    map.recentre();
  } else if (mode === 'battle' && ['f', 'r', 'h'].includes(ev.key)) {
    run(ev.key);
  }
});

// ---------- panel pieces ----------

/** A button that runs a command. Outlined unless attrs.class says otherwise. */
const btn = (label, line, attrs = {}) =>
  m('button', { type: 'button', onclick: () => run(line), ...attrs, class: attrs.class ?? 'outline' }, label);

const MENU_TITLES = {
  go: 'Go', grind: 'Grind', shop: 'Shop', cast: 'Cast', items: 'Items',
  more: 'More', status: 'Status', checklist: 'Checklist', danger: 'Danger', options: 'Options', about: 'About',
};
/** The menus under More. */
const MORE = ['status', 'checklist', 'danger', 'options', 'about'];

function openMenu(name) {
  S.menu = name;
  if (name === 'danger') S.danger = S.engine.danger();
}

function back() {
  S.menu = MORE.includes(S.menu) ? 'more' : null;
}

/** A button that opens a menu in place of the commands. */
const menuBtn = (label, name, attrs = {}) =>
  m('button', { type: 'button', onclick: () => openMenu(name), ...attrs, class: attrs.class ?? 'outline' }, label);

const ACTION_LABELS = {
  take: 'Take', search: 'Search', talk: 'Talk', open: 'Open door', stairs: 'Stairs', herb: 'Herb',
  leave: 'Leave', inn: 'Inn', shop: 'Shop', save: 'Save', mp: 'Restore MP',
};

function Status() {
  const g = S.view.game;
  // The whole line opens Status, when a menu can open.
  const open = S.view.mode === 'command' ? { onclick: () => openMenu('status') } : {};
  return m('header.status', { ...open, class: g.low_hp ? 'low' : '' }, [
    m('div.line', [
      m('span', `Lv ${g.level}`),
      m('span.hp', `HP ${g.hp}/${g.max_hp}`),
      m('span.mp', `MP ${g.mp}/${g.max_mp}`),
      m('span.gold', `${g.gold} G`),
    ]),
    !prefs.showWhere ? null : m('div.line.where', [
      m('span', `${g.x}, ${g.y}`),
      g.zone != null ? m('span', `zone ${g.zone}`) : null,
      m('span', `${g.encounter.toFixed(1)}% a step`),
    ]),
  ]);
}

/** The row over a menu or prompt: Back, and what it is. */
function Header(title, onBack) {
  return m('div.menubar', [
    m('button.outline.back', { type: 'button', onclick: onBack }, '< Back'),
    m('h6', title),
  ]);
}

/** The main buttons, most used first: what's underfoot, then town services, then travel. */
const ORDER = {
  town: ['take', 'stairs', 'open', 'inn', 'shop', 'go', 'leave', 'save', 'mp', 'items', 'cast', 'herb', 'talk', 'grind', 'search', 'more', 'auto'],
  field: ['take', 'stairs', 'open', 'go', 'grind', 'items', 'cast', 'herb', 'talk', 'search', 'more', 'auto'],
};

function Commands() {
  const g = S.view.game;
  if (S.menu) return [Header(MENU_TITLES[S.menu], back), m('section.menu', Menu[S.menu]())];
  const all = {
    go: menuBtn('Go\u00a0>', 'go'),
    grind: menuBtn('Grind\u00a0>', 'grind'),
    items: menuBtn('Items\u00a0>', 'items'),
    cast: g.spells.some((s) => s.field) ? menuBtn('Cast\u00a0>', 'cast') : null,
    more: menuBtn('More\u00a0>', 'more'),
    auto: btn(g.auto ? 'Auto-battle: on' : 'Auto-battle: off', g.auto ? 'auto off' : 'auto on', { class: g.auto ? '' : 'outline' }),
  };
  for (const a of g.actions) {
    all[a] = a === 'shop' ? menuBtn('Shop\u00a0>', 'shop')
      : a === 'inn' ? btn(`Inn · ${g.inn} G`, 'inn', { class: 'outline' })
        : btn(ACTION_LABELS[a] ?? a, a, { class: 'outline' });
  }
  return m('nav.buttons.main', ORDER[g.town ? 'town' : 'field'].map((k) => all[k] ?? null));
}

const Menu = {
  more: () => m('nav.buttons.list', MORE.map((k) => menuBtn(MENU_TITLES[k], k))),
  go() {
    const g = S.view.game;
    const dist = (p) => (g.map === 1 ? ` · ${Math.abs(p.x - g.x) + Math.abs(p.y - g.y)}` : '');
    const todo = g.checklist.filter((o) => !o.done);
    return [
      RiskPicker(),
      m('h6', 'Towns'),
      m('nav.buttons.list', g.towns.map((t) => btn(`${t.name}${dist(t)}`, goCommand(t.name.toLowerCase()), { disabled: g.town === t.name }))),
      todo.length ? m('h6', 'Checklist') : null,
      m('nav.buttons.list', todo.map((o) => btn(`${o.n}. ${o.name}`, goCommand(o.n), { title: o.where + (o.needs ? ` (needs ${o.needs})` : '') }))),
      g.map === 1 ? [m('h6', 'Places'), m('nav.buttons.list', g.landmarks.map((l) => btn(l.name, goCommand(`${l.x} ${l.y}`))))] : null,
      m('p.hint', 'Or tap the map.'),
    ];
  },
  grind() {
    return [
      m('nav.buttons', btn('Grind', `grind ${prefs.fights}${prefs.grindAuto ? ' auto' : ''} stop=${prefs.grindStop}`, { class: 'wide' })),
      m('label', ['Fights ',
        m('select', { value: prefs.fights, onchange: (e) => { prefs.fights = Number(e.target.value); savePrefs(); } },
          [3, 5, 10, 20, 50].map((n) => m('option', { value: n }, n)))]),
      m('label', [m('input[type=checkbox]', { checked: prefs.grindAuto, onchange: (e) => { prefs.grindAuto = e.target.checked; savePrefs(); } }), ' Auto-battle']),
      StopStepper('grindStop'),
    ];
  },
  cast() {
    const g = S.view.game;
    return m('nav.buttons', g.spells.filter((s) => s.field).map((s) =>
      btn(`${s.name} · ${s.mp}`, `cast ${s.name}`, { disabled: g.mp < s.mp })));
  },
  items() {
    const g = S.view.game;
    if (!g.items.length) return m('p.hint', 'You carry nothing.');
    const selling = g.shop.length > 0;
    return [
      m('div.rows', g.items.map((it) => m('div.row', [
        m('span', `${it.name}${it.count > 1 ? ` ×${it.count}` : ''}${it.worn ? ' (worn)' : ''}`),
        it.name === 'Magic Key' ? m('span') : btn('Use', `use ${it.n}`),
        selling ? (it.sell != null ? btn(`Sell · ${it.sell} G`, `sell ${it.n}`, { class: 'outline' }) : m('span')) : null,
      ]))),
      m('p.hint', `Equipped: ${g.weapon ?? 'no weapon'}, ${g.armor ?? 'no armor'}, ${g.shield ?? 'no shield'}.`),
    ];
  },
  shop() {
    const g = S.view.game;
    const groups = [];
    for (const o of g.shop) {
      if (!groups.length || groups.at(-1).shop !== o.shop) groups.push({ shop: o.shop, kind: o.kind, offers: [] });
      groups.at(-1).offers.push(o);
    }
    return groups.map((gr) => [
      m('h6', gr.kind),
      m('nav.buttons', gr.offers.map((o) =>
        btn([m('span', o.name), m('small', `${o.price} G`)], `buy ${o.n}`, { class: 'outline tile', disabled: o.price > g.gold }))),
    ]).concat(m('p.hint', 'Weapons and armor are traded in when you buy. Sell from Items.'));
  },
  status() {
    const g = S.view.game;
    // Pairs flow into as many columns as fit; the long ones take a whole row.
    const row = (k, v, wide) => m('div', { class: wide ? 'wide' : '' }, [m('span.k', k), m('span', v)]);
    return m('div.stats', [
      row('Name', g.name), row('Level', g.level), row('HP', `${g.hp}/${g.max_hp}`), row('MP', `${g.mp}/${g.max_mp}`),
      row('Strength', g.str), row('Agility', g.agi), row('Attack', g.attack), row('Defense', g.defense),
      row('Experience', g.xp + (g.xp_to_next != null ? ` (${g.xp_to_next} to next)` : ''), true), row('Gold', g.gold),
      row('Herbs', g.herbs), row('Keys', g.keys),
      row('Weapon', g.weapon ?? '-'), row('Armor', g.armor ?? '-'), row('Shield', g.shield ?? '-'),
      row('Spells', g.spells.map((s) => `${s.name} (${s.mp})`).join(', ') || '-', true),
      g.repel_steps ? row('Repel', `${g.repel_steps} steps`) : null,
      row('Steps', g.steps), row('Battles', g.battles),
    ]);
  },
  checklist() {
    const g = S.view.game;
    return m('div.checklist', g.checklist.map((o) => m('div.objective', { class: o.done ? 'done' : '' }, [
      m('span.n', `${o.n}.`),
      m('div', [
        m('b', o.name), o.optional ? m('span.hint', ' optional') : null,
        o.done ? null : m('div.hint', o.where + (o.needs ? ` - needs ${o.needs}` : '')),
      ]),
      o.done ? m('span.hint', 'done') : btn('Go', goCommand(o.n), { class: 'outline' }),
    ])));
  },
  danger() {
    const d = S.danger;
    if (!d) return null;
    return [
      m('p.hint', `One fight, for you as you are now (HP ${d.hp}).`),
      m('table.danger', [
        m('thead', m('tr', [m('th', 'Zone'), m('th.right', 'HP lost'), m('th.right', 'Death'), m('th', 'Enemies')])),
        m('tbody', d.zones.map((z) => m('tr', { class: z.zone === d.here ? 'here' : '' }, [
          m('td', z.zone), m('td.right', z.loss.toFixed(1)), m('td.right', `${z.death.toFixed(0)}%`),
          m('td', z.enemies.join(', ') + (z.zone >= 14 ? ' (caves)' : '')),
        ]))),
      ]),
    ];
  },
  about() {
    const link = (href, text) => m('a', { href, target: '_blank', rel: 'noopener' }, text);
    const credit = (what, by, license) => m('div.credit', [m('b', what), m('div.hint', [by, ' - ', license])]);
    return m('div.about', [
      m('p.hint', 'This is Dragon Warrior minus the walking, basically. Dragon Warrior is a trademark of Square Enix; this is an unofficial fan project, not affiliated with or endorsed by them.'),
      m('h6', 'Credits'),
      credit('Anvil font', ['ZX Origins by DamienG, ', link('https://damieng.com/zx-origins', 'damieng.com/zx-origins')], 'used with permission'),
      credit('1-Bit Pack (map tiles)', ['Kenney, ', link('https://kenney.nl', 'kenney.nl')], 'CC0'),
      credit('Input Prompts Pixel 1-Bit (map buttons)', ['Kenney, ', link('https://kenney.nl', 'kenney.nl')], 'CC0'),
      credit('Pico CSS', link('https://picocss.com', 'picocss.com'), 'MIT'),
      credit('Mithril', link('https://mithril.js.org', 'mithril.js.org'), 'MIT'),
    ]);
  },
  options() {
    return [
      m('label.check', [
        m('input[type=checkbox]', { checked: prefs.assist, onchange: (e) => { prefs.assist = e.target.checked; savePrefs(); S.engine.setAssist(prefs.assist); refresh(); } }),
        ' Remake conveniences',
        m('div.hint', 'Step onto stairs to take them and onto a chest to open it - routes with no fights, damage, guards or doors are walked without asking.'),
      ]),
      m('label.check', [
        m('input[type=checkbox]', { checked: prefs.showLog, onchange: (e) => { prefs.showLog = e.target.checked; savePrefs(); } }),
        ' Show the log',
        m('div.hint', 'Above the buttons - drag its lower edge to resize it.'),
      ]),
      m('label.check', [
        m('input[type=checkbox]', { checked: prefs.showCmd, onchange: (e) => { prefs.showCmd = e.target.checked; savePrefs(); } }),
        ' Show the command line',
      ]),
      m('label.check', [
        m('input[type=checkbox]', { checked: prefs.showWhere, onchange: (e) => { prefs.showWhere = e.target.checked; savePrefs(); } }),
        ' Show coordinates and encounter rate',
        m('div.hint', 'A second status line: where you stand, the zone and the chance of a fight each step.'),
      ]),
      m('h6', 'Save file'),
      m('p.hint', 'Only the king saves (Tantegel throne room). The save is kept in this browser, in the same 8 KB format as the CLI\'s drgnwrrr.sav.'),
      m('nav.buttons', [
        m('button.outline', { type: 'button', onclick: exportSave, disabled: !S.engine.hasSave() }, 'Export .sav'),
        m('label.button.outline', ['Import .sav', m('input[type=file][hidden]', { accept: '.sav', onchange: importSave })]),
        m('button.outline', { type: 'button', onclick: () => { newGame(); S.menu = null; } }, 'New game'),
      ]),
    ];
  },
};

function RiskPicker() {
  return [
    m('div.segmented', { role: 'group' }, ['safe', 'balanced', 'fast'].map((r) =>
      m('button', { type: 'button', class: prefs.risk === r ? '' : 'outline', onclick: () => { prefs.risk = r; savePrefs(); } }, r))),
    StopStepper('stop'),
  ];
}

/** − and + buttons rather than a slider, which a touch scroll would drag. */
function StopStepper(key) {
  const by = (d) => () => { prefs[key] = Math.min(90, Math.max(0, prefs[key] + d)); savePrefs(); };
  return m('div.stepper', [
    m('button.outline', { type: 'button', 'aria-label': 'Stop sooner', disabled: prefs[key] <= 0, onclick: by(-10) }, '−'),
    m('span', { 'aria-live': 'polite' }, `Stop under ${prefs[key]}% HP`),
    m('button.outline', { type: 'button', 'aria-label': 'Stop later', disabled: prefs[key] >= 90, onclick: by(10) }, '+'),
  ]);
}

function ConfirmRoute() {
  const r = S.view.game.route;
  const replan = (risk) => {
    prefs.risk = risk;
    savePrefs();
    run('n', { echo: false });
    if (S.lastGo) run(S.lastGo.replace(/\b(safe|balanced|fast)\b/, risk));
  };
  return m('section.prompt', [
    Header(`To ${r.name}`, () => run('n')),
    m('nav.buttons', btn('Walk', walkCommand(), { class: 'wide' })),
    m('div.segmented', ['safe', 'balanced', 'fast'].map((k) =>
      m('button', { type: 'button', class: r.risk === k ? '' : 'outline', onclick: () => r.risk !== k && replan(k) }, k))),
    StopStepper('stop'),
    S.tapped ? m('p.hint', 'Or tap the same tile again.') : null,
    m('dl.route', [
      m('dt', 'Steps'), m('dd', r.steps),
      m('dt', 'Fights'), m('dd', `~${r.fights.toFixed(1)}`),
      m('dt', 'HP loss'), m('dd', `~${r.hp_loss.toFixed(0)} of ${S.view.game.hp}`),
      m('dt', 'Death'), m('dd', { class: r.death >= 10 ? 'bad' : '' }, `${r.death.toFixed(1)}%`),
      r.worst_zone != null ? [m('dt', 'Zone'), m('dd', `up to ${r.worst_zone}`)] : null,
      r.doors ? [m('dt', 'Doors'), m('dd', { class: r.doors > r.keys ? 'bad' : '' }, `${r.doors} (${r.keys} keys)`)] : null,
      r.via.length ? [m('dt', 'Via'), m('dd', r.via.join(', '))] : null,
    ]),
    r.fixed ? m('p.bad', `${r.fixed} guarded tile(s) on the way.`) : null,
  ]);
}

function Battle() {
  const g = S.view.game;
  const b = g.battle;
  const spells = g.spells.filter((s) => s.battle);
  const flags = [b.enemy_asleep && 'asleep', b.enemy_stopped && 'spells blocked'].filter(Boolean);
  const mine = [b.hero_asleep && 'you are asleep', b.hero_stopped && 'your spells are blocked'].filter(Boolean);
  return m('section.prompt.battle', [
    m('h5', [b.enemy, flags.length ? m('small', ` (${flags.join(', ')})`) : null]),
    mine.length ? m('p.bad', mine.join('; ')) : null,
    m('nav.buttons', [
      btn('Fight', 'f', { class: '' }),
      btn('Run', 'r', { class: 'outline' }),
      g.herbs ? btn(`Herb · ${g.herbs}`, 'h', { class: 'outline' }) : null,
      g.items.some((it) => it.name === 'Fairy Flute') ? btn('Flute', 'flute', { class: 'outline' }) : null,
      btn('Auto', 'a', { class: 'outline' }),
      b.job ? btn(b.stopping ? 'Stopping' : b.job === 'grind' ? 'Stop grind' : 'Stop walk', 'stop', { class: 'outline', disabled: b.stopping, title: 'Finish this fight, then stop' }) : null,
      // One grid, so every row stretches alike; the spells start a row of their own.
      spells.map((s, i) =>
        btn(`${s.name} · ${s.mp}`, `c ${s.name}`, { class: i ? 'outline' : 'outline newrow', disabled: g.mp < s.mp || b.hero_stopped })),
    ]),
  ]);
}

function MakeRoom() {
  const g = S.view.game;
  return m('section.prompt', [
    m('h5', `Your bag is full: ${g.make_room}`),
    m('p.hint', 'Throw something away for it?'),
    m('nav.buttons', [
      ...g.items.filter((it) => it.droppable && it.name !== 'Herb' && it.name !== 'Magic Key').map((it) => btn(it.name, String(it.n), { class: 'outline' })),
      btn('Leave it', 'leave', { class: 'outline' }),
    ]),
  ]);
}

function Dragonlord() {
  return m('section.prompt', [
    m('h5', S.view.question.trim()),
    m('nav.buttons', [btn('Yes', 'y'), btn('No', 'n', { class: '' })]),
  ]);
}

function Title() {
  const named = (e) => {
    e.preventDefault();
    const name = e.target.elements.name.value.trim();
    if (name) run(name, { echo: false });
  };
  return m('section.prompt.title', [
    m('h4', 'drgnwrrr'),
    m('p.hint', 'This is basically Dragon Warrior minus the walking. Is it still fun? I don\'t know!'),
    S.view.has_save ? m('nav.buttons', [m('button.wide', { type: 'button', onclick: continueGame }, 'Continue')]) : null,
    m('form', { onsubmit: named }, [
      m('label', [S.view.has_save ? 'Or start over: your name' : 'Your name',
      m('input', { name: 'name', maxlength: 8, autocomplete: 'off', placeholder: '1-8 letters', value: 'Erdrick', required: true })]),
      m('button[type=submit]', { class: S.view.has_save ? 'outline' : '' }, 'New game'),
    ]),
  ]);
}

function Over() {
  return m('section.prompt', [
    m('h5', 'The end'),
    m('nav.buttons', [m('button', { type: 'button', onclick: () => { newGame(); } }, 'New game')]),
  ]);
}

const Log = {
  onupdate: ({ dom }) => { dom.scrollTop = dom.scrollHeight; },
  oncreate: ({ dom }) => { dom.scrollTop = dom.scrollHeight; },
  view: () => m('section.log', { 'aria-live': 'polite' }, S.log.map((l) => m('div', { class: `${l.kind}${l.fresh ? ' fresh' : ''}` }, l.text || ' '))),
};

function CommandLine() {
  return m('form.cmdline', {
    onsubmit: (e) => {
      e.preventDefault();
      const input = e.target.elements.cmd;
      const line = input.value.trim();
      input.value = '';
      if (line === 'help' || line === '?' || S.view.mode !== 'name') run(line);
      else if (line) run(line, { echo: false });
    },
  }, m('input', { name: 'cmd', autocomplete: 'off', autocapitalize: 'off', spellcheck: false, placeholder: 'type a command (help)', 'aria-label': 'Command' }));
}

const Panel = {
  view() {
    if (S.error) return m('section.prompt', [m('h5', 'Something went wrong'), m('pre', S.error)]);
    if (!S.view) return m('p.hint', 'Loading…');
    const mode = S.view.mode;
    const body = mode === 'name' ? Title()
      : mode === 'confirm_route' ? ConfirmRoute()
        : mode === 'battle' ? Battle()
          : mode === 'make_room' ? MakeRoom()
            : mode === 'dragonlord' ? Dragonlord()
              : mode === 'over' ? Over()
                : Commands();
    const log = prefs.showLog && S.view.game;
    return m('div.inner', { class: S.menu || mode === 'confirm_route' ? 'menu-open' : '' }, [
      S.view.game ? Status() : null,
      m('div.split', { style: `--log: ${prefs.logSize * 100}%` }, [
        log ? m(Log) : null,
        log ? m('div.splitter', { role: 'separator', 'aria-label': 'Resize the log', onpointerdown: dragLog }) : null,
        m('div.controls', body),
      ]),
      prefs.showCmd ? CommandLine() : null,
    ]);
  },
};

// ---------- resizing ----------

/** Follow a pointer drag on a splitter, calling move(event) until it lets go. */
function drag(e, move, done) {
  e.preventDefault();
  const el = e.currentTarget;
  el.setPointerCapture(e.pointerId);
  el.classList.add('dragging');
  const up = () => {
    el.removeEventListener('pointermove', move);
    el.removeEventListener('pointerup', up);
    el.removeEventListener('pointercancel', up);
    el.classList.remove('dragging');
    done();
  };
  el.addEventListener('pointermove', move);
  el.addEventListener('pointerup', up);
  el.addEventListener('pointercancel', up);
}

/** The log's share of the room under the status line. */
function dragLog(e) {
  const box = e.currentTarget.parentElement.getBoundingClientRect();
  drag(e, (ev) => {
    prefs.logSize = Math.min(0.8, Math.max(0.08, (ev.clientY - box.top) / box.height));
    m.redraw();
  }, savePrefs);
}

const sideBySide = matchMedia('(orientation: landscape) and (min-width: 700px)');

/** The panel's size, kept as its width beside the map and its height under it. */
function applyPanelSize() {
  const root = document.documentElement.style;
  if (prefs.panelW) root.setProperty('--panel-w', `${prefs.panelW}px`);
  if (prefs.panelH) root.setProperty('--panel-h', `${prefs.panelH}px`);
}

function dragPanel(e) {
  const across = sideBySide.matches;
  drag(e, (ev) => {
    if (across) prefs.panelW = Math.round(Math.min(innerWidth * 0.7, Math.max(260, innerWidth - ev.clientX)));
    else prefs.panelH = Math.round(Math.min(innerHeight * 0.75, Math.max(160, innerHeight - ev.clientY)));
    applyPanelSize();
  }, savePrefs);
}

const Hud = {
  view() {
    const g = S.view?.game;
    if (!g) return null;
    const h = S.hover;
    return m('div.hud', [
      m('span', g.town ?? g.map_name),
      h ? m('span.hover', h.label ?? `${h.name} ${h.x}, ${h.y}`) : null,
    ]);
  },
};

// ---------- saves ----------

function continueGame() {
  const r = S.engine.continueGame();
  if (r.out) say(r.out);
  if (fixedSeed !== null) S.engine.reseed(fixedSeed);
  refresh();
}

function exportSave() {
  const blob = new Blob([S.engine.saveData()], { type: 'application/octet-stream' });
  const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: 'drgnwrrr.sav' });
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

async function importSave(e) {
  const file = e.target.files[0];
  if (!file) return;
  const bytes = new Uint8Array(await file.arrayBuffer());
  const before = S.engine.saveData();
  S.engine.loadSaveData(bytes);
  if (!S.engine.hasSave()) {
    S.engine.loadSaveData(before);
    say('  That file has no save in it.', 'warn');
  } else {
    store.set(SAVE_KEY, toBase64(S.engine.saveData()));
    S.menu = null;
    continueGame();
  }
  m.redraw();
}

// ---------- start ----------

async function start() {
  m.mount(document.getElementById('panel'), Panel);
  m.mount(document.getElementById('hud'), Hud);
  m.mount(document.getElementById('mapctl'), MapControls);
  applyPanelSize();
  document.getElementById('divider').addEventListener('pointerdown', dragPanel);
  try {
    S.engine = await loadEngine();
  } catch (err) {
    S.error = String(err);
    m.redraw();
    return;
  }
  S.engine.boot(fixedSeed ?? crypto.getRandomValues(new Uint32Array(1))[0]);
  S.engine.setAssist(prefs.assist);
  const saved = store.get(SAVE_KEY);
  if (saved) {
    try {
      S.engine.loadSaveData(fromBase64(saved));
    } catch {
      say('  The stored save couldn\'t be read.', 'warn');
    }
  }
  refresh();
  m.redraw();
}

start();
