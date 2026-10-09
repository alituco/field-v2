"""Extract the two embedded, OFL-licensed fonts from the supplied prototype.

Usage: python scripts/extract-fieldrush-fonts.py '/path/to/Fieldrush App.html'
Requires fonttools and brotli. Does not execute the HTML or its JavaScript.
"""
import base64
import io
import json
from pathlib import Path
import re
import sys

from fontTools.ttLib import TTFont

source = Path(sys.argv[1]).read_text()
manifest = json.loads(re.search(
    r'<script type="__bundler/manifest">(.*?)</script>', source, re.S
).group(1))
output = Path(__file__).resolve().parents[1] / 'mobile/assets/fonts'
output.mkdir(parents=True, exist_ok=True)
for family, asset in {
    'Outfit': '41c71791-b449-4815-b6a3-813f913380f5',
    'PlusJakartaSans': '0eca9eba-7c66-4327-835b-46d4f322dd29',
}.items():
    entry = manifest[asset]
    assert entry['mime'] == 'font/woff2' and not entry['compressed']
    font = TTFont(io.BytesIO(base64.b64decode(entry['data'])))
    font.flavor = None
    font.save(output / f'{family}.ttf')
    print(f'Extracted {family}')
