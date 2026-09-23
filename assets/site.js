// site.js
//
// Liest config/mods.json und rendert die Seite KOMPLETT aus den JSON-Daten.
//
//  1. Normal  : GET config/mods.json (lokal oder GitHub Pages)
//  2. Fallback: raw.githubusercontent.com/<owner>/<repo>/<branch>/config/mods.json
//               (falls Pages die .json-Datei nicht roh ausliefert)
//
// Es gelten KEINE festen Annahmen über die Mods: id, modId, version, project,
// homepage, filename, url, size, sha1, sha512, match, note und alle _meta-Felder
// werden generisch ausgelesen und angezeigt. Neue Mods erscheinen automatisch.

(function () {
  'use strict';

  var BRANCH = 'main';     // Standard-Branch fürs Raw-Fallback
  var CFG = 'config/mods.json';
  var META_ORDER = ['name', 'description', 'minecraft', 'loader', 'source', 'rule'];
  var LIST_FIELDS = ['movedFrom', 'movedTo'];
  var MIRROR_FIELDS = ['modrinthApi', 'modrinthCdn', 'fabricMeta', 'fabricMaven'];
  var INSTALLER_DEF_KEYS = ['home', 'cli', 'minecraft', 'loader', 'installer'];

  // ------------------------------------------------------------------
  // Utilities
  // ------------------------------------------------------------------
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function isArr(v) { return Array.isArray(v); }
  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }

  function humanSize(b) {
    var n = Number(b);
    if (!isFinite(n)) return '—';
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
    return (n / 1073741824).toFixed(2) + ' GB';
  }

  function fmtHash(v) {
    var s = String(v || '');
    if (s.length > 16) { return s.slice(0, 16) + '…'; }
    return s;
  }

  // ------------------------------------------------------------------
  // Domain (Fallback für die Raw-URL)
  // ------------------------------------------------------------------
  function domain() {
    var parts = (window.location.pathname || '').replace(/\/$/, '').split('/').filter(Boolean);
    if (parts.length >= 2) { return { owner: parts[0], repo: parts[1], path: parts.slice(2).join('/') }; }
    var h = (window.location.hostname || '').split('.');
    if (h.length >= 3)       { return { owner: h[0], repo: h[1], path: '' }; }
    return { owner: '', repo: '', path: '' };
  }

  // ------------------------------------------------------------------
  // Rendering
  // ------------------------------------------------------------------
  function normalizeMeta(data) {
    var meta0 = isObj(data) ? data : {};
    var meta = {};
    if (isObj(meta0._meta)) { Object.keys(meta0._meta).forEach(function (k) { meta[k] = meta0._meta[k]; }); }
    Object.keys(meta0).forEach(function (k) { if (k !== '_meta') meta[k] = meta0[k]; });
    return meta;
  }

  function render(data) {
    var meta = normalizeMeta(data);
    var mods = isArr(data.mods) ? data.mods : [];
    var app = document.getElementById('app');
    var h = [];

    // Kopf
    var name = meta.name || 'Mods-Index';
    var desc = meta.description || '';

    h.push('<header>');
    h.push('  <h1 id="name">' + esc(name) + '<span class="sep"> /</span> mods.json</h1>');
    if (desc) h.push('  <p id="desc">' + esc(desc) + '</p>');
    h.push('</header>');

    // Fakten
    var factPairs = [];
    if (meta.minecraft != null) factPairs.push(['Minecraft', meta.minecraft]);
    if (meta.loader != null) factPairs.push(['Loader', meta.loader]);
    if (meta.source != null) factPairs.push(['Quelle', meta.source]);
    factPairs.push(['Mods', String(mods.length)]);
    if (meta.schema != null) factPairs.push(['Schema', meta.schema]);
    if (meta.released != null) factPairs.push(['Stand', meta.released]);

    if (factPairs.length) {
      h.push('<dl class="facts">');
      factPairs.forEach(function (p) {
        h.push('  <div><dt>' + esc(p[0]) + '</dt><dd>' + esc(p[1]) + '</dd></div>');
      });
      h.push('</dl>');
    }

    // Regeln (generisch aus meta.rule)
    var rule = meta.rule;
    if (isObj(rule) && Object.keys(rule).length) {
      h.push('<h2>Regeln (Manifest)</h2>');
      h.push('<table class="rules"><thead><tr><th>Situation</th><th>Entscheidung</th></tr></thead><tbody>');
      Object.keys(rule).forEach(function (k) {
        h.push('<tr><td>' + esc(k) + '</td><td>' + esc(rule[k]) + '</td></tr>');
      });
      h.push('</tbody></table>');
    }

    // Mods
    h.push('<h2>Mods (' + mods.length + ')</h2>');
    if (!mods.length) {
      h.push('<p class="note">Keine Mods in config/mods.json gefunden.</p>');
    }
    h.push('<section id="mods">');
    mods.forEach(function (m) { h.push(renderMod(m)); });
    h.push('</section>');

    // Installer (aus installer.json, im Client gelesen)
    h.push('<h2>Installer</h2>');
    h.push('<div id="installer"><p class="note">Lade config/installer.json …</p></div>');

    app.innerHTML = h.join('\n');

    // Installer nachladen (separate Datei)
    loadInstaller();
  }

  function renderList(m, label, key) {
    var v = m[key];
    if (!isArr(v)) return '';
    return '<dt>' + esc(label) + '</dt><dd><div class="chips">' +
      v.map(function (x) { return '<span class="chip">' + esc(x) + '</span>'; }).join('') +
      '</div></dd>';
  }

  function renderHash(m, label, key) {
    var v = m[key];
    if (!v) return '';
    return '<dt>' + esc(label) + '</dt><dd class="mono mut" title="' + esc(v) + '">' + esc(fmtHash(v)) + '</dd>';
  }

  function renderUrl(m, label, key) {
    var v = m[key];
    if (!v) return '';
    return '<dt>' + esc(label) + '</dt><dd class="hl-block"><a href="' + esc(v) + '" target="_blank" rel="noopener">' + esc(v) + '</a></dd>';
  }

  function renderMod(m) {
    var id = m.id || '';
    var modId = m.modId || '';
    var title = m.title || id || '(unbenannt)';
    var version = m.version != null ? m.version : '—';
    var homepage = m.homepage || m.url || '';

    var out = [];
    out.push('<article class="mod">');
    out.push('  <div class="mod-head">');
    out.push('    <div class="row">');
    out.push('      <h3>' + (homepage ? '<a href="' + esc(homepage) + '" target="_blank" rel="noopener">' + esc(title) + '</a>' : esc(title)) +
               (m.project ? '<span class="project">' + esc(m.project) + '</span>' : '') + '</h3>');
    out.push('      <span class="ver">' + esc(version) + '</span>');
    out.push('    </div>');
    out.push('    <p><span class="id">id:</span> ' + esc(id) + (modId ? ' <span class="id">· modId:</span> ' + esc(modId) : '') + '</p>');
    out.push('  </div>');

    // alle übrigen Felder generisch
    var pairs = [];
    function push(label, html) { if (html) pairs.push('<div>' + html + '</div>'); }

    push('filename', m.filename ? '<dt>filename</dt><dd class="mono">' + esc(m.filename) + '</dd>' : '');
    push('url', renderUrl(m, 'url', 'url'));
    push('homepage', m.homepage ? '<dt>homepage</dt><dd class="mono"><a href="' + esc(m.homepage) + '" target="_blank" rel="noopener">' + esc(m.homepage) + '</a></dd>' : '');
    push('size', m.size != null ? '<dt>size</dt><dd class="mono">' + esc(String(m.size)) + ' (' + esc(humanSize(m.size)) + ')</dd>' : '');
    push('sha1', renderHash(m, 'sha1', 'sha1'));
    push('sha512', renderHash(m, 'sha512', 'sha512'));
    push('match', renderList(m, 'match', 'match'));
    push('note', m.note ? '<dt>note</dt><dd class="mut">' + esc(m.note) + '</dd>' : '');

    // Projekt- & Versions-Link (Modrinth-Stil)
    if (m.project) {
      pairs.push('<div><dt>Modrinth</dt><dd class="mono"><a href="https://modrinth.com/mod/' + esc(m.project) +
        (m.version != null ? '/version/' + esc(String(m.version)) : '') + '" target="_blank" rel="noopener">modrinth.com/mod/' +
        esc(m.project) + (m.version != null ? '/version/' + esc(String(m.version)) : '') + '</a></dd></div>');
    }

    // Weitere unbekannte Felder aus dem JSON (generisch - letzte Worte)
    var known = ['id', 'modId', 'title', 'version', 'project', 'homepage', 'filename', 'url', 'size', 'sha1', 'sha512', 'match', 'note'];
    Object.keys(m).forEach(function (k) {
      if (known.indexOf(k) !== -1) return;
      var v = m[k];
      if (isArr(v)) { push(k, renderList(m, k, k)); }
      else if (isObj(v)) { push(k, '<dt>' + esc(k) + '</dt><dd class="mut">' + esc(JSON.stringify(v)) + '</dd>'); }
      else { push(k, '<dt>' + esc(k) + '</dt><dd class="mono">' + esc(String(v)) + '</dd>'); }
    });

    out.push('  <dl class="fields">');
    out.push(pairs.join('\n'));
    out.push('  </dl>');
    out.push('</article>');
    return out.join('\n');
  }

  function renderInstaller(inst) {
    var instKey = (inst && inst.installer) || {};
    var loader = (inst && inst.loader) || {};
    var mc = (inst && inst.minecraft) || {};
    var box = document.getElementById('installer');
    if (!box) return;

    // Wenn keine installer.json -> nur den CLI-Befehl aus den Mods-Daten
    var rows = [];
    function addHtml(l, v) { if (v) rows.push('<dt>' + esc(l) + '</dt><dd class="mono">' + esc(v) + '</dd>'); }

    if (Object.keys(instKey).length) {
      addHtml('version', instKey.version);
      addHtml('name', instKey.name);
      addHtml('url', instKey.url);
      addHtml('sha1', instKey.sha1);
      addHtml('sha512', instKey.sha512);
      addHtml('cli', instKey.cli);
    }
    if (Object.keys(loader).length) { addHtml('loader', loader.version); }
    if (Object.keys(mc).length) { addHtml('minecraft', mc.version); }

    var html = '';
    if (rows.length) {
      html = '<dl class="fields">' + rows.join('') + '</dl>';
    } else {
      html = '<p class="note">config/installer.json nicht gefunden.</p>';
    }

    // CLI-Befehl immer anzeigen (aus installer.json.cli oder generisch)
    if (instKey.cli) {
      html += '<pre><code>' + esc(instKey.cli) + '</code></pre>';
    }
    box.innerHTML = html;
  }

  // ------------------------------------------------------------------
  // Übrige (unbekannte) Felder generisch ans Ende
  // ------------------------------------------------------------------
  function renderMetaOptional(data) {
    var meta = normalizeMeta(data);
    var app = document.getElementById('app');
    var known = ['name', 'description', 'minecraft', 'loader', 'source', 'schema', 'released', 'rule', 'mods'];
    var extra = [];
    Object.keys(meta).forEach(function (k) {
      if (known.indexOf(k) !== -1) return;
      var v = meta[k];
      if (isArr(v)) {
        extra.push('<h2>' + esc(k) + '</h2><div class="chips">' +
          v.map(function (x) { return '<span class="chip">' + esc(x) + '</span>'; }).join('') + '</div>');
      } else if (isObj(v)) {
        var inner = Object.keys(v).map(function (kk) { return '<div class="hl-block">' + esc(kk) + ': ' + esc(String(v[kk])) + '</div>'; }).join('');
        extra.push('<h2>' + esc(k) + '</h2>' + inner);
      } else {
        extra.push('<h2>' + esc(k) + '</h2><p class="note mono">' + esc(String(v)) + '</p>');
      }
    });
    if (extra.length) {
      app.insertAdjacentHTML('beforeend', extra.join('\n'));
    }
  }

  // ------------------------------------------------------------------
  // Loader
  // ------------------------------------------------------------------
  function request(url, done) {
    var x = new XMLHttpRequest();
    x.open('GET', url, true);
    x.onreadystatechange = function () {
      if (x.readyState === 4) {
        if (x.status === 200) { try { done(null, JSON.parse(x.responseText)); } catch (e) { done(e); } }
        else { done(new Error('HTTP ' + x.status)); }
      }
    };
    x.onerror = function () { done(new Error('netzwerkfehler')); };
    x.send(null);
  }

  function loadInstaller() {
    var d = domain();
    var candidates = ['config/installer.json'];
    if (d.owner && d.repo) {
      candidates.push('https://raw.githubusercontent.com/' + d.owner + '/' + d.repo + '/' + BRANCH +
                      (d.path ? '/' + d.path : '') + '/config/installer.json');
    }
    tryEach(candidates, 0, function (err, inst) {
      var box = document.getElementById('installer');
      if (!box) return;
      if (err || !isObj(inst)) {
        box.innerHTML = '<p class="note">config/installer.json: ' + esc(err ? err.message : 'nicht gefunden') + '</p>';
        return;
      }
      renderInstaller(inst);
    });
  }

  function tryEach(urls, i, done) {
    if (i >= urls.length) { return done(new Error('alle Quellen fehlgeschlagen')); }
    request(urls[i], function (err, data) {
      if (err) { return tryEach(urls, i + 1, done); }
      done(null, data);
    });
  }

  function fail(msg) {
    var app = document.getElementById('app');
    if (app) {
      app.innerHTML = '<p class="error">config/mods.json konnte nicht geladen werden. ' +
        'Details: ' + esc(msg || 'unbekannt') + '<br>' +
        'Erwartet wird die Datei neben index.html (config/mods.json) oder im Repo.</p>';
    }
  }

  // ------------------------------------------------------------------
  // Start
  // ------------------------------------------------------------------
  function boot() {
    var d = domain();
    var candidates = [CFG];
    if (d.owner && d.repo) {
      candidates.push('https://raw.githubusercontent.com/' + d.owner + '/' + d.repo + '/' + BRANCH +
                      (d.path ? '/' + d.path : '') + '/' + CFG);
    }
    tryEach(candidates, 0, function (err, data) {
      if (err || !isObj(data)) { return fail(err ? err.message : 'ungültiges JSON'); }
      render(data);
      renderMetaOptional(data);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
