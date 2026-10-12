"""Compose README artwork from real renders; requires Pillow on macOS."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
images = root / 'docs/images'
fonts = Path('/System/Library/Fonts/Supplemental')

def font(size, bold=False):
    return ImageFont.truetype(str(fonts / ('Arial Bold.ttf' if bold else 'Arial.ttf')), size)

bg, card, fg, muted, lime = '#080a0c', '#111417', '#f3f1ea', '#aeb0ad', '#c9ff4a'
hero = Image.new('RGB', (1600, 820), bg)
d = ImageDraw.Draw(hero)
d.rounded_rectangle((1050, 60, 1540, 760), radius=42, fill=card, outline='#272d28', width=2)
standing = Image.open(images/'aero-standing.png').convert('RGBA')
standing.thumbnail((520, 700))
hero.paste(standing, (1035, 60), standing)
d.text((80, 75), 'PARLA AI TUOI PROGETTI', fill=lime, font=font(24, True))
d.text((75, 138), 'ORBIT', fill=fg, font=font(106, True))
d.text((80, 288), 'Il tuo assistente vocale.', fill=fg, font=font(44, True))
d.text((80, 351), 'Sul tuo Mac. Con i tuoi strumenti.', fill=muted, font=font(30))
d.rounded_rectangle((80, 440, 950, 565), radius=22, fill=card, outline='#33392a', width=2)
d.text((110, 466), '“Hey Orbit, avvia il progetto in locale.”', fill=fg, font=font(29))
d.text((110, 514), 'VOCE  →  PROGETTO  →  RISULTATO', fill=lime, font=font(20, True))
for x, title, text in [(80, 'NATIVO', 'macOS + SwiftUI'), (390, 'MULTI SESSIONE', 'Più progetti insieme'), (700, 'LOCALE O CLOUD', 'Codex · Ollama · LM Studio')]:
    d.text((x, 644), title, fill=lime, font=font(18, True))
    d.text((x, 682), text, fill=muted, font=font(20))
hero.save(images/'orbit-hero.png', optimize=True)

poses = Image.new('RGB', (1560, 860), bg)
d = ImageDraw.Draw(poses)
d.text((50, 38), 'AERO', fill=fg, font=font(40, True))
d.text((50, 99), 'La mascotte 3D di Orbit · modello e animazioni reali', fill=muted, font=font(24))
for index, (filename, title, detail) in enumerate([
    ('aero-standing.png', 'PRONTO', 'In piedi, al tuo fianco'),
    ('aero-greeting.png', 'CIAO!', 'Saluto all’apertura'),
    ('aero-thinking.png', 'RAGIONAMENTO', 'Un momento per pensare'),
]):
    x = 30 + index*510
    d.rounded_rectangle((x, 165, x+480, 815), radius=28, fill=card, outline='#252a2d', width=2)
    im = Image.open(images/filename).convert('RGBA')
    im.thumbnail((420, 535))
    poses.paste(im, (x+(480-im.width)//2, 170), im)
    d.text((x+30, 715), title, fill=lime, font=font(25, True))
    d.text((x+30, 760), detail, fill=muted, font=font(22))
poses.save(images/'aero-poses.png', optimize=True)
