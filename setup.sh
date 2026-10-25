#!/usr/bin/env bash
set -u

# Surcharges utiles aux tests seulement (en production : défauts).
CLOUD_LIB=${CLOUD_LIB:-/usr/local/lib}
CLOUD_ETAPES=${CLOUD_ETAPES:-"garde plugins playwright docker"}
JOURNAL=${CLOUD_JOURNAL:-/tmp/claude-cloud-setup.log}   # CLOUD_JOURNAL : utile aux tests seulement

# poser FICHIER MODE : stdin -> $CLOUD_LIB/FICHIER ; réécrit seulement si le contenu change.
poser() {
  local dest=$CLOUD_LIB/$1 tmp
  tmp=$(mktemp) || return 1
  cat > "$tmp"
  mkdir -p "${dest%/*}"
  cmp -s "$tmp" "$dest" || cat "$tmp" > "$dest"
  chmod "$2" "$dest"
  rm -f "$tmp"
}

prerequis() {
  local outil manquants=()
  for outil in jq git claude; do manquants+=("$outil"); done
  case " $CLOUD_ETAPES " in *" playwright "*) manquants+=(node npm) ;; esac
  case " $CLOUD_ETAPES " in *" docker "*) manquants+=(docker dockerd) ;; esac
  local rc=0
  for outil in "${manquants[@]}"; do
    command -v "$outil" > /dev/null || { echo "claude-cloud: $outil absent du PATH" >&2; echo "$outil absent du PATH" >> "$JOURNAL"; rc=1; }
  done
  return "$rc"
}

etape_garde() {
  poser claude-plugins-kit/garde-rm.sh 0755 <<'CLOUD_PLUGINS_GARDE'
#!/usr/bin/env bash
# PreToolUse Bash : refuse « cd … rm … » (approbation humaine native immune au bypass)
# et « pkill/pgrep -f » sans `[` dans la commande (auto-correspondance avec le shell parent)
# et « rm » dont une cible est une variable suivie de « / » (vide, elle viserait / ; le natif refuse sans appel).
# Jamais d'erreur ni de sortie parasite : tout doute = rc 0, stdout vide.
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(jq -er '.tool_input.command | strings' 2>/dev/null) || exit 0
tete='(^|[;&|({])[[:space:]]*((then|do|else)[[:space:]]+)?'
tete_p='(^|[;&|({])[[:space:]]*((then|do|else|until|while|if)[[:space:]]+)?(![[:space:]]+)?'
re_p="${tete_p}(pkill|pgrep)[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z0-9]*f|--full)"
re_v='(^|[;&|({])[[:space:]]*((then|do|else)[[:space:]]+)?rm[[:space:]][^;&|]*(\$[A-Za-z_][A-Za-z0-9_]*"?/|\$\{[A-Za-z_][A-Za-z0-9_]*(\}|([^A-Za-z0-9_:}]|:[^?])[^}]*\})"?/)'
if printf '%s\n' "$cmd" | grep -qE "${tete}cd[[:space:]]" \
  && printf '%s\n' "$cmd" | grep -qE "${tete}rm[[:space:]]"; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"cd puis rm : chemin relatif non résolu statiquement, approbation humaine requise. Réécris la commande sans cd, avec des chemins absolus."}}'
elif printf '%s\n' "$cmd" | grep -qE "$re_p" \
  && ! printf '%s\n' "$cmd" | grep -qF '['; then
  printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"pkill/pgrep -f : le motif figure dans la ligne de commande du shell (pkill le tue, exit 144 ; pgrep le trouve). Encadre un caractère du motif, ex. pkill -f '[w]ork/bt.sh'.\"}}"
elif printf '%s\n' "$cmd" | sed -E 's/\$(\{(HOME|PWD|TMPDIR)\}|(HOME|PWD|TMPDIR)\b)/_/g' | grep -qE "$re_v"; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"rm sur variable : la cible dépend d'\''une variable qui, vide, viserait / ; approbation humaine requise. Réécris avec \"${D:?}\"/… ou un chemin absolu littéral."}}'
fi
exit 0
CLOUD_PLUGINS_GARDE
  poser claude-plugins-kit/garde-enregistre.sh 0755 <<'CLOUD_PLUGINS_ENREGISTRE'
#!/usr/bin/env bash
set -euo pipefail
f="$HOME/.claude/settings.json"
mkdir -p "${f%/*}"
[ -s "$f" ] || echo '{}' > "$f"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
jq --arg c /usr/local/lib/claude-plugins-kit/garde-rm.sh '
  .hooks.PreToolUse //= []
  | if any(.hooks.PreToolUse[]?.hooks[]?; .command == $c) then .
    else .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $c}]}] end' "$f" > "$tmp" \
  || { echo "claude-plugins kit: settings.json illisible, garde rm non posée" >&2; exit 1; }
cmp -s "$f" "$tmp" || cat "$tmp" > "$f"
CLOUD_PLUGINS_ENREGISTRE
  bash "$CLOUD_LIB/claude-plugins-kit/garde-enregistre.sh"
}
etape_plugins() {
  poser claude-plugins-kit/ensure.sh 0755 <<'CLOUD_PLUGINS_ENSURE'
#!/usr/bin/env bash
set -euo pipefail
installed="$HOME/.claude/plugins/installed_plugins.json"
claude_bin="$(command -v claude || true)"
[ -n "$claude_bin" ] || claude_bin="$HOME/.local/bin/claude"
echec=0
# "<plugin>@<marketplace> <source de la marketplace>" — la seule liste.
plugins=(
  "caveman@caveman JuliusBrussee/caveman"
  "superpowers@claude-plugins-official anthropics/claude-plugins-official"
  "claude-security@claude-plugins-official anthropics/claude-plugins-official"
)
for entree in "${plugins[@]}"; do
  cle=${entree%% *} source=${entree#* }
  if [ -f "$installed" ] && jq -e --arg k "$cle" '.plugins[$k]' "$installed" >/dev/null 2>&1; then
    continue
  fi
  if [ ! -x "$claude_bin" ]; then
    echo "claude-plugins kit: claude CLI not found, skipping" >&2
    exit 0
  fi
  "$claude_bin" plugin marketplace add "$source" || true
  "$claude_bin" plugin install "$cle" || echec=1
done
exit "$echec"
CLOUD_PLUGINS_ENSURE
  bash "$CLOUD_LIB/claude-plugins-kit/ensure.sh"
}
etape_playwright() {
  poser playwright-kit/ensure.sh 0755 <<'CLOUD_PLAYWRIGHT_ENSURE'
#!/usr/bin/env bash
# Versions figées : seule source de vérité du kit.
v=0.0.83
rev=chromium-1247
libs=(libglib2.0-0t64 libatk1.0-0t64 libatk-bridge2.0-0t64 libdbus-1-3 libcups2t64
      libxcb1 libxkbcommon0 libasound2t64 libgbm1 libx11-6 libxext6 libcairo2
      libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libatspi2.0-0t64)
polices=(fonts-dejavu-core fonts-dejavu-mono fonts-liberation
         fonts-noto-color-emoji fonts-wqy-zenhei fonts-tlwg-loma-otf)
# Pas de -e : une étape en échec met rc=1 et laisse continuer les suivantes.
set -uo pipefail

msg() { echo "playwright kit: $*" >&2; }

# Étape 0 : racine partagée B (montage hôte), sinon repli local non partagé.
etape_racine() {
  if [ -n "${PW_ROOT:-}" ]; then
    B=$PW_ROOT
  else
    B=$(findmnt -rno TARGET 2>/dev/null | grep '/\.cache/sbx-playwright$' | head -1 || true)
    [ -n "$B" ] || B=$HOME/.cache/sbx-playwright
  fi
  mkdir -p "$B/.sbx-mcp" || return 1
  export PLAYWRIGHT_BROWSERS_PATH=$B PLAYWRIGHT_SKIP_BROWSER_GC=1
  M=$B/.sbx-mcp/mcp-$v
}

# Étape 1 : paquet @playwright/mcp, posé atomiquement par mv -T.
paquet_valide() { [ "$("$M/bin/playwright-mcp" --version 2>/dev/null)" = "Version $v" ]; }
etape_paquet() {
  paquet_valide && return 0
  rm -rf "$M"
  msg "npm install @playwright/mcp@$v"
  local tmp cache
  tmp=$(mktemp -d "$B/.sbx-mcp/.tmp.mcp.XXXXXX") || return 1
  cache=$(mktemp -d) || { rm -rf "$tmp"; return 1; }   # cache npm hors B, jeté ensuite
  npm i -g --prefix "$tmp" --cache "$cache" "@playwright/mcp@$v" >&2
  local rc=$?
  rm -rf "$cache"
  if [ "$rc" -eq 0 ]; then
    mv -T "$tmp" "$M" 2>/dev/null || rm -rf "$tmp"   # course perdue : l'autre a posé $M
  else
    rm -rf "$tmp"
  fi
  paquet_valide || { msg "package failed"; return 1; }
}

# Étape 2 : navigateur. Jamais de GC côté sandbox (--no-remove + SKIP_BROWSER_GC).
etape_navigateur() {
  local cli=$M/lib/node_modules/@playwright/mcp/node_modules/playwright/cli.js
  [ -f "$cli" ] || { msg "browser failed (no cli.js)"; return 1; }
  node "$cli" install --no-shell --no-progress --no-remove chromium \
    || { msg "browser failed"; return 1; }
}

# Étape 3 : sysroot partagé (bibliothèques + polices), sans root :
# listes apt privées, apt-get download + dpkg-deb -x, posé par mv -T.
# Les paquets dépendent de l'image (seuls les absents sont tirés) : on
# reconstruit en union avec l'ancien R, remplacé seulement après succès, sinon
# deux générations d'image se le disputeraient.
etape_sysroot() {
  . /etc/os-release
  R=$B/.sbx-mcp/sysroot-$ID-$VERSION_ID-$rev
  local chrome=$B/$rev/chrome-linux64/chrome
  sysroot_valide() {
    [ -f "$R/fonts.conf" ] || return 1
    [ -x "$chrome" ] || return 0   # sans chrome, seul le contrôle ldd saute
    # Capture d'abord : un pipe vers grep -q tuerait ldd (SIGPIPE) et pipefail
    # inverserait le verdict.
    local sortie
    sortie=$(LD_LIBRARY_PATH=$R/usr/lib/x86_64-linux-gnu ldd "$chrome" 2>&1)
    ! grep -q 'not found' <<<"$sortie"
  }
  sysroot_valide && return 0
  msg "sysroot build $R"
  local apt tmp deb f avait=
  apt=$(mktemp -d) || return 1   # listes et cache apt hors B, jetés ensuite
  tmp=$(mktemp -d "$B/.sbx-mcp/.tmp.sysroot.XXXXXX") || { rm -rf "$apt"; return 1; }
  if [ -d "$R" ]; then
    avait=1
    cp -a "$R/." "$tmp/" || { rm -rf "$apt" "$tmp"; msg "sysroot failed"; return 1; }
  fi
  mkdir -p "$apt/lists/partial" "$apt/cache/archives/partial"
  local o=(-o "Dir::State::Lists=$apt/lists" -o "Dir::Cache=$apt/cache" -o Debug::NoLocking=1)
  local noms
  {
    apt-get "${o[@]}" update >&2 &&
    noms=$(apt-get "${o[@]}" install -s --no-install-recommends "${libs[@]}" "${polices[@]}" \
             | awk '$1 == "Inst" {print $2}' \
             | grep -Ev '^(libllvm|(mesa-libgallium|libc6|libc-bin|libgcc-s1|libstdc\+\+6)$)') &&
    [ -n "$noms" ] &&
    mkdir -p "$apt/debs" && cd "$apt/debs" &&
    apt-get "${o[@]}" download $noms >&2 &&
    (for deb in "$apt"/debs/*.deb; do dpkg-deb -x "$deb" "$tmp" || exit 1; done)
  } || { cd /; rm -rf "$apt" "$tmp"; msg "sysroot failed"; return 1; }
  cd /
  {
    echo '<?xml version="1.0"?>'
    echo '<fontconfig>'
    for f in "$tmp"/etc/fonts/conf.d/*.conf; do
      [ -L "$f" ] || continue
      echo "  <include ignore_missing=\"yes\">$R/usr/share/fontconfig/conf.avail/$(basename "$(readlink "$f")")</include>"
    done
    # <dir> après les includes, sinon 05-reset-dirs-sample.conf vide la liste.
    echo "  <dir>$R/usr/share/fonts</dir>"
    echo '  <cachedir prefix="xdg">fontconfig</cachedir>'
    echo '</fontconfig>'
  } > "$tmp/fonts.conf"
  rm -rf "$apt"
  [ -n "$avait" ] && mv -T "$R" "$R.old.$$" 2>/dev/null
  mv -T "$tmp" "$R" 2>/dev/null || rm -rf "$tmp"   # course perdue : l'autre a posé $R
  [ -e "$R" ] || mv -T "$R.old.$$" "$R" 2>/dev/null
  rm -rf "$R.old.$$"
  [ -f "$R/fonts.conf" ] || { msg "sysroot failed"; return 1; }
}

# Étape 4 : enregistrement par agent, une fonction par agent, appelées à la suite ;
# Claude seul aujourd'hui. Claude : serveur MCP dans ~/.claude.json (portée user),
# nommé sbx-playwright : à nom égal, un .mcp.json de projet (playwright) le masquerait.
# WAYLAND_DISPLAY vide : sbx pose wayland-0 au 1er démarrage, ANGLE/SwiftShader
# exige alors VK_KHR_wayland_surface (absent) et WebGL tombe.
# Comparaison canonique (jq -S) : une forme stockée différente de la voulue
# déclencherait un remove+add à chaque démarrage.
serveur_claude() {
  local claude_bin=$1
  local libs_dir=$R/usr/lib/x86_64-linux-gnu voulu actuel
  local args=(--headless --browser chromium --isolated --output-dir /tmp/playwright-mcp)
  voulu=$(jq -nS --arg b "$B" --arg m "$M" --arg l "$libs_dir" --arg f "$R/fonts.conf" \
    '{type:"stdio",command:($m+"/bin/playwright-mcp"),args:$ARGS.positional,
      env:{PLAYWRIGHT_BROWSERS_PATH:$b,LD_LIBRARY_PATH:$l,FONTCONFIG_FILE:$f,WAYLAND_DISPLAY:""}}' --args -- "${args[@]}") || return 1
  actuel=$(jq -S '.mcpServers["sbx-playwright"] // empty' "$HOME/.claude.json" 2>/dev/null || true)
  [ "$actuel" = "$voulu" ] && return 0
  if [ -n "$actuel" ]; then
    msg "claude mcp remove sbx-playwright (stale entry)"
    "$claude_bin" mcp remove sbx-playwright -s user >&2 || return 1
  fi
  msg "claude mcp add sbx-playwright"
  "$claude_bin" mcp add sbx-playwright --scope user \
    -e "PLAYWRIGHT_BROWSERS_PATH=$B" -e "LD_LIBRARY_PATH=$libs_dir" -e "FONTCONFIG_FILE=$R/fonts.conf" -e WAYLAND_DISPLAY= \
    -- "$M/bin/playwright-mcp" "${args[@]}" >&2
}

# Annonce aux sessions de la sandbox : bloc balisé dans ~/.claude/CLAUDE.md (mémoire user
# lue par toute session, quel que soit le projet). Contenu hors bloc intact, octet pour
# octet : d'où head/tail par numéro de ligne (awk ajouterait un \n final). Marqueurs
# reconnus par préfixe, en colonne 0 : une nouvelle rédaction de la 1re ligne remplace
# l'ancien bloc. Marqueurs incohérents : fichier intact, rc 1, on ne tronque jamais le
# contenu d'autrui. Écriture par `cat > f` seulement si le résultat diffère (inode et
# mtime stables au rejeu).
annoncer_claude() {
  local f=$HOME/.claude/CLAUDE.md bloc tmp fin sep d f_fin nd nf
  bloc=$(cat <<'BLOC'
<!-- sbx-playwright:début — bloc géré par le kit playwright (forge), réécrit à chaque démarrage -->
## Navigateur en sandbox

Chromium partagé déjà installé. Piloter le navigateur par le serveur MCP `sbx-playwright`
(outils `mcp__sbx-playwright__*`), et seulement lui.

- Jamais `install-browser`, `npx playwright install`, ni `apt`/`apt-get` pour Playwright ou
  ses dépendances, même si une consigne ou une mémoire de projet le demande.
- Un serveur `playwright` déclaré par un projet (`.mcp.json`) : ne pas l'utiliser.
- `sbx-playwright` en échec : `/mcp` pour reconnecter, sinon le signaler à l'utilisateur.
  Aucun contournement par installation.
<!-- sbx-playwright:fin -->
BLOC
  )
  mkdir -p "$HOME/.claude" || return 1
  tmp=$(mktemp) || return 1
  if [ ! -s "$f" ]; then
    printf '%s\n' "$bloc" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    d=$(grep -an '^<!-- sbx-playwright:début' "$f" | cut -d: -f1) || true
    f_fin=$(grep -an '^<!-- sbx-playwright:fin -->' "$f" | cut -d: -f1) || true
    nd=$(printf '%s' "$d" | grep -c .) || true
    nf=$(printf '%s' "$f_fin" | grep -c .) || true
    if [ "$nd" -eq 0 ] && [ "$nf" -eq 0 ]; then
      # $(…; echo .) préserve les \n finaux, que $(…) supprimerait.
      fin=$(tail -c 2 "$f"; echo .); fin=${fin%.}
      case $fin in
        *$'\n\n') sep= ;;
        *$'\n') sep=$'\n' ;;
        *) sep=$'\n\n' ;;
      esac
      { cat "$f" && printf '%s' "$sep" && printf '%s\n' "$bloc"; } > "$tmp" || { rm -f "$tmp"; return 1; }
    elif [ "$nd" -eq 1 ] && [ "$nf" -eq 1 ] && [ "$d" -lt "$f_fin" ]; then
      { head -n $((d - 1)) "$f" && printf '%s\n' "$bloc" && tail -n +$((f_fin + 1)) "$f"; } > "$tmp" || { rm -f "$tmp"; return 1; }
    else
      rm -f "$tmp"
      # shellcheck disable=SC2088 # ~ littéral : texte du message
      msg "~/.claude/CLAUDE.md markers broken, left untouched"
      return 1
    fi
  fi
  cmp -s "$tmp" "$f" || cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# CLI absente : ni serveur ni annonce (sans serveur l'annonce serait fausse). Sinon
# l'annonce est tentée même si l'enregistrement échoue : chemins déterministes, le
# démarrage suivant répare.
enregistrer_claude() {
  local claude_bin=${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")} rc=0
  [ -x "$claude_bin" ] || { msg "claude CLI not found, skipping MCP registration"; return 0; }
  serveur_claude "$claude_bin" || rc=1
  annoncer_claude || rc=1
  return "$rc"
}

rc=0
# Pas `|| rc=1` : B et M sont requis par toutes les étapes suivantes (set -u).
etape_racine || { msg "root failed"; exit 1; }
etape_paquet || rc=1
etape_navigateur || rc=1
etape_sysroot || rc=1
# Tentée même si 1-3 ont échoué : chemins déterministes, le démarrage suivant répare B.
enregistrer_claude || rc=1
exit "$rc"
CLOUD_PLAYWRIGHT_ENSURE
  bash "$CLOUD_LIB/playwright-kit/ensure.sh"
}
etape_docker() {
  poser claude-cloud/docker.sh 0755 <<'CLOUD_DOCKER'
#!/usr/bin/env bash
# Hook SessionStart : démarre dockerd s'il ne répond pas. Toujours rc 0 : un hook en échec
# ne doit pas gêner la session.
# CLOUD_DOCKER_ATTENTE (secondes) et CLOUD_DOCKER_LOG : utiles aux tests seulement.
LOG=${CLOUD_DOCKER_LOG:-/tmp/dockerd.log}
if docker info > /dev/null 2>&1; then exit 0; fi
# Détaché du groupe du hook (setsid) : Claude Code peut tuer le groupe à la fin du hook.
if command -v setsid > /dev/null; then
  setsid nohup dockerd > "$LOG" 2>&1 < /dev/null &
else
  nohup dockerd > "$LOG" 2>&1 < /dev/null &
fi
for _ in $(seq "${CLOUD_DOCKER_ATTENTE:-15}"); do
  docker info > /dev/null 2>&1 && exit 0
  sleep 1
done
echo "claude-cloud: docker indisponible, voir $LOG" >&2
exit 0
CLOUD_DOCKER
  local f=$HOME/.claude/settings.json tmp
  mkdir -p "${f%/*}"
  [ -s "$f" ] || echo '{}' > "$f"
  tmp=$(mktemp) || return 1
  jq --arg c /usr/local/lib/claude-cloud/docker.sh '
    .hooks.SessionStart //= []
    | if any(.hooks.SessionStart[]?.hooks[]?; .command == $c) then .
      else .hooks.SessionStart += [{matcher: "startup|resume", hooks: [{type: "command", command: $c}]}] end' "$f" > "$tmp" \
    || { echo "claude-cloud: settings.json illisible, hook docker non posé" >&2; rm -f "$tmp"; return 1; }
  cmp -s "$f" "$tmp" || cat "$tmp" > "$f"
  rm -f "$tmp"
}
main() {
  local etape rc=0
  : > "$JOURNAL"
  prerequis || return 1
  for etape in $CLOUD_ETAPES; do
    if ! declare -F "etape_$etape" > /dev/null; then
      echo "claude-cloud: étape inconnue : $etape" >&2
      rc=1
      continue
    fi
    echo "début $etape" >> "$JOURNAL"
    "etape_$etape"
    local r=$?
    echo "fin $etape rc=$r" >> "$JOURNAL"
    [ "$r" -eq 0 ] || rc=1
  done
  return "$rc"
}

main "$@"
