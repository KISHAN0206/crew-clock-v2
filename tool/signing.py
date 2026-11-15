"""Signs release builds with the permanent Crew Clock key, so updates install over the old app.

Run after `dart run tool/setup.dart`, with the key already decoded to android/app/crewclock.jks.
The password comes from the CREWCLOCK_KEY_PASSWORD environment variable at build time.
"""
import os
import re
import sys

KTS_CONFIG = '''    signingConfigs {
        create("release") {
            keyAlias = "crewclock"
            keyPassword = System.getenv("CREWCLOCK_KEY_PASSWORD")
            storeFile = file("crewclock.jks")
            storePassword = System.getenv("CREWCLOCK_KEY_PASSWORD")
        }
    }

'''

GROOVY_CONFIG = '''    signingConfigs {
        release {
            keyAlias 'crewclock'
            keyPassword System.getenv('CREWCLOCK_KEY_PASSWORD')
            storeFile file('crewclock.jks')
            storePassword System.getenv('CREWCLOCK_KEY_PASSWORD')
        }
    }

'''


def patch(path, text):
    kts = path.endswith('.kts')
    if 'crewclock.jks' in text:
        return text
    m = re.search(r'^(\s*)buildTypes\s*\{', text, re.M)
    if not m:
        sys.exit(f'Could not find buildTypes in {path}')
    text = text[:m.start()] + (KTS_CONFIG if kts else GROOVY_CONFIG) + text[m.start():]
    if kts:
        text, n = re.subn(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
                          'signingConfig = signingConfigs.getByName("release")', text)
    else:
        text, n = re.subn(r'signingConfig\s+signingConfigs\.debug', 'signingConfig signingConfigs.release', text)
    if n == 0:
        # No debug signing line in the template: add one to the release build type.
        line = '            signingConfig = signingConfigs.getByName("release")\n' if kts else \
            '            signingConfig signingConfigs.release\n'
        text, n = re.subn(r'(buildTypes\s*\{\s*(?:getByName\("release"\)|release)\s*\{\n)', r'\1' + line.replace('\\', '\\\\'), text, count=1)
        if n == 0:
            sys.exit(f'Could not set the release signing config in {path}')
    return text


for path in ('android/app/build.gradle.kts', 'android/app/build.gradle'):
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            original = f.read()
        updated = patch(path, original)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(updated)
        print(f'Release signing set in {path}')
        break
else:
    sys.exit('android/app/build.gradle(.kts) not found. Run tool/setup.dart first.')
