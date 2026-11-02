"""Adds Jaybel Office Choice branding to the Android app.

Run after `dart run tool/setup.dart` (the android/ folder must exist):
    python3 tool/brand.py

Uses these files if present (the GitHub build downloads them from the Office Choice site):
    assets/brand/logo-white.png   white + yellow logo, for red backgrounds
    assets/brand/logo-red.png     logo on its red panel
    assets/brand/icon.png         red "OIC" smiley icon
"""
import os
import shutil

from PIL import Image

RED = (0xDA, 0x29, 0x1C)
RES = 'android/app/src/main/res'
BRAND = 'assets/brand'

# Flat GitHub uploads put logo files in the repo root; move them into assets/brand.
os.makedirs(BRAND, exist_ok=True)
for name in ('logo-white.png', 'logo-red.png', 'icon.png'):
    if os.path.exists(name) and not os.path.exists(os.path.join(BRAND, name)):
        shutil.move(name, os.path.join(BRAND, name))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


# ---- App icon: the red OIC smiley, squared up on red ----
icon_src = os.path.join(BRAND, 'icon.png')
if os.path.exists(icon_src):
    src = Image.open(icon_src).convert('RGBA')
    side = max(src.size)
    bg = src.getpixel((2, 2))[:3]  # the icon's own red
    square = Image.new('RGBA', (side, side), bg + (255,))
    square.paste(src, ((side - src.width) // 2, (side - src.height) // 2), src)
    for folder, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        out = os.path.join(RES, f'mipmap-{folder}', 'ic_launcher.png')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        square.resize((px, px), Image.LANCZOS).save(out)
    print('App icon: Office Choice smiley')
else:
    print('App icon: icon.png not found, keeping the default icon')

# ---- Launch screen: Office Choice red with the white logo ----
logo_src = os.path.join(BRAND, 'logo-white.png')
has_logo = os.path.exists(logo_src)
if has_logo:
    logo = Image.open(logo_src).convert('RGBA')
    # Trim transparent edges, then scale to a comfortable width for tablets.
    bbox = logo.getbbox()
    if bbox:
        logo = logo.crop(bbox)
    width = 560
    logo = logo.resize((width, round(logo.height * width / logo.width)), Image.LANCZOS)
    out = os.path.join(RES, 'drawable-nodpi', 'splash_logo.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    logo.save(out)

hex_red = '#%02X%02X%02X' % RED
layers = f'''<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item><color android:color="{hex_red}" /></item>
''' + ('''    <item><bitmap android:gravity="center" android:src="@drawable/splash_logo" /></item>
''' if has_logo else '') + '''</layer-list>
'''
for folder in ('drawable', 'drawable-v21'):
    write(os.path.join(RES, folder, 'launch_background.xml'), layers)

# Android 12+ draws its own splash: red background with the app icon.
styles = f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:windowSplashScreenBackground">{hex_red}</item>
        <item name="android:windowSplashScreenAnimatedIcon">@mipmap/ic_launcher</item>
    </style>
    <style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar">
        <item name="android:windowBackground">?android:colorBackground</item>
    </style>
</resources>
'''
for folder in ('values-v31', 'values-night-v31'):
    write(os.path.join(RES, folder, 'styles.xml'), styles)

print('Launch screen: red' + (' with logo' if has_logo else ' (logo not found)'))
