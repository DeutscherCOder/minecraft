// Rendert die Mod-Liste + Regeln + Copy-Paste-Commands direkt aus config/mods.json
// => Installer und Website teilen sich EINE Datenquelle.

(function () {
  'use strict';

  // Escape für die sichere Einbettung von Manifest-Text in HTML
  function esc(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function humanSize(bytes) {
    var b = Number(bytes);
    if (!isFinite(b)) return '—';
    if (b < 1024) return b + ' B';
    if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
    if (b < 1024 * 1024 * 1024) return (b / 1024 / 1024).toFixed(1) + ' MB';
    return (b / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  }

  function shortSha(sha) {
    if (!sha) return '—';
    return sha.slice(0, 10) + '…';
  }

  var ruleRows = [
    ['Mod vorhanden, <b>exakte</b> SHA-1/SHA-512 stimmt', '<span class="pill" style="color:#7ff0b2">BEHALTEN</span>'],
    ['Gleiche Mod, <b>andere Version</b> (Dateiname-Muster)', '<span class="pill" style="color:#ffd479">BACKUP</span> → <code>mods-backup\&lt;zeitstempel&gt;\</code>'],
    ['Unbekannte <code>.jar</code>-Datei', '<span class="pill" style="color:#ffd479">BACKUP</span> → <code>mods-backup\&lt;zeitstempel&gt;\</code>'],
    ['Gewünschte Mod fehlt / beschädigt', '<span class="pill" style="color:#79b8ff">DOWNLOAD</span> von Modrinth + Prüfsumme']
  ];

  var urlBase = 'https://modrinth.com/mod/';

  function renderRules() {
    var body = document.getElementById('rules-body');
    if (!body) return;
    body.innerHTML = ruleRows.map(function (r) {
      return '<tr><td>' + r[0] + '</td><td>' + r[1] + '</td></tr>';
    }).join('');
  }

  function renderMods(mods) {
    var body = document.getElementById('mods-body');
    var urls = document.getElementById('urls-list');
    if (document.getElementById('hero-modcount')) {
      document.getElementById('hero-modcount').textContent = mods.length + ' Mods';
    }

    if (body) {
      body.innerHTML = mods.map(function (m) {
        var home = 'https://modrinth.com/mod/' + (m.project || m.id);
        return '<tr>' +
          '<td class="mod-name"><a href="' + esc(home) + '" target="_blank" rel="noopener">' + esc(m.title) + '</a>' +
            (m.id === 'dreamshift' ? ' <span class="pill">Haupt-Mod</span>' : '') +
            (m.note ? '<div style="color:#8296a8;font-size:12px;margin-top:4px">' + esc(m.note) + '</div>' : '') +
          '</td>' +
          '<td>' + esc(m.version) + '</td>' +
          '<td><code>' + esc(m.filename) + '</code></td>' +
          '<td class="size">' + humanSize(m.size) + '</td>' +
          '<td class="sha">' + esc(shortSha(m.sha1)) + '</td>' +
          '<td></td>' +
        '</tr>';
      }).join('');
    }

    if (urls) {
      urls.innerHTML = mods.map(function (m) {
        return '<li><span>' + esc(m.title) + ' ' + esc(m.version) + '</span><br>' + esc(m.url) + '</li>';
      }).join('');
    }
  }

  function done(mods) {
    renderRules();
    renderMods(mods);
  }

  // Manifest (lokale Datei) zuerst versuchen -> funktioniert, wenn jemand die
  // Website lokal öffnet ODER auf GitHub Pages (dort liegt config/ mit im Repo).
  var req = new XMLHttpRequest();
  req.open('GET', 'config/mods.json', true);
  req.onreadystatechange = function () {
    if (req.readyState === 4) {
      if (req.status === 200) {
        try { done(JSON.parse(req.responseText).mods); } catch (e) { fail(); }
      } else {
        fallbackRaw();
      }
    }
  };
  req.onerror = fallbackRaw;
  req.send();

  function fallbackRaw() {
    // GitHub Pages rendert config/mods.json evtl. als Template -> Raw-Branch laden
    var raw = new XMLHttpRequest();
    var pagePath = (window.location.pathname || '').replace(/\/$/, '');
    var parts = pagePath.split('/').filter(Boolean); // [user, repo, ...]
    if (parts.length >= 2) {
      var owner = parts[0], repo = parts[1];
      var branch = 'main';
      var path = parts.slice(2).join('/');
      var cfgUrl = 'https://raw.githubusercontent.com/' + owner + '/' + repo + '/' + branch + (path ? '/' + path : '') + '/config/mods.json';
      raw.open('GET', cfgUrl, true);
      raw.onreadystatechange = function () {
        if (raw.readyState === 4) {
          if (raw.status === 200) {
            try { done(JSON.parse(raw.responseText).mods); } catch (e) { fail(); }
          } else { fail(); }
        }
      };
      raw.send();
    } else {
      fail();
    }
  }

  function fail() {
    var body = document.getElementById('mods-body');
    if (body) body.innerHTML = '<tr><td colspan="6" class="loading">Mod-Liste konnte nicht geladen werden (config/mods.json siehe Repo).</td></tr>';
    renderRules();
  }

  // Copy-Buttons
  document.querySelectorAll('button.copy').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var target = document.getElementById(btn.getAttribute('data-copy-target'));
      if (!target) return;
      var text = target.innerText;
      var done = function () {
        var old = btn.textContent;
        btn.textContent = 'Kopiert!';
        btn.classList.add('copied');
        setTimeout(function () { btn.textContent = old; btn.classList.remove('copied'); }, 1400);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { legacyCopy(text); done(); });
      } else { legacyCopy(text); done(); }
    });
  });

  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(ta);
  }
})();
