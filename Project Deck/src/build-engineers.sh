#!/bin/zsh
# Build Project Deck/tiler-engineers.html from src/tiler-engineers.src.html:
# inline the UI screenshots, embed the BikS2013 lockups, add the deck menu, verify.
set -euo pipefail
cd "$(dirname "$0")/.."
SK="${NBG_DESIGN_SKILL:?set NBG_DESIGN_SKILL to the nbg-design skill folder}"
python3 - <<'PY'
import base64
src = open('src/tiler-engineers.src.html').read()
shots = {'SHOT_SHORTCUTS':'settings-shortcuts.png','SHOT_OVERLAY':'shortcuts-overlay.png',
         'SHOT_MENU':'menu.png','SHOT_GENERAL':'settings-general.png'}
for tok, f in shots.items():
    if '{{'+tok+'}}' in src:
        uri = 'data:image/png;base64,' + base64.b64encode(open('screenshots/'+f,'rb').read()).decode()
        src = src.replace('{{'+tok+'}}', uri)
open('tiler-engineers.html','w').write(src)
PY
node "$SK/scripts/embed-assets.mjs" tiler-engineers.html --theme biks2013
node "$SK/scripts/add-deck-menu.mjs" tiler-engineers.html --theme biks2013
node "$SK/scripts/verify-deck.mjs" tiler-engineers.html --strict
