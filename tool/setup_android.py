import os, re, shutil, glob
A = 'android/app'
for d in glob.glob('tool/res/mipmap-*'):
    t = f'{A}/src/main/res/{os.path.basename(d)}'; os.makedirs(t, exist_ok=True)
    shutil.copy(d + '/ic_launcher.png', t + '/ic_launcher.png')
shutil.copy('sync.jks', A + '/sync.jks')
mp = f'{A}/src/main/AndroidManifest.xml'; m = open(mp).read()
m = re.sub(r'android:label="[^"]*"', 'android:label="Sync-musiC"', m, 1)
perms = ''.join(f'<uses-permission android:name="android.permission.{p}"/>\n' for p in ['INTERNET', 'WAKE_LOCK', 'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_MEDIA_PLAYBACK', 'POST_NOTIFICATIONS'])
m = m.replace('<application', perms + '<application', 1)
m = m.replace('android:name=".MainActivity"', 'android:name="com.ryanheise.audioservice.AudioServiceActivity"', 1)
act = '''<meta-data android:name="flutter_deeplinking_enabled" android:value="false"/>
<intent-filter android:autoVerify="true">
<action android:name="android.intent.action.VIEW"/>
<category android:name="android.intent.category.DEFAULT"/>
<category android:name="android.intent.category.BROWSABLE"/>
<data android:scheme="https" android:host="music.thesync.my.id"/>
</intent-filter>
</activity>'''
m = m.replace('</activity>', act, 1)
svc = '''<service android:name="com.ryanheise.audioservice.AudioService" android:foregroundServiceType="mediaPlayback" android:exported="true">
<intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
</service>
<receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
<intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
</receiver>
</application>'''
m = m.replace('</application>', svc, 1)
open(mp, 'w').write(m)
kts = os.path.exists(A + '/build.gradle.kts')
gp = A + ('/build.gradle.kts' if kts else '/build.gradle'); g = open(gp).read()
if kts:
    blk = 'signingConfigs { create("release") { storeFile = file("sync.jks"); storePassword = "Pa52QntsYLkgLqSL"; keyAlias = "sync"; keyPassword = "Pa52QntsYLkgLqSL" } }\n    buildTypes {'
    g = g.replace('buildTypes {', blk, 1).replace('signingConfigs.getByName("debug")', 'signingConfigs.getByName("release")')
else:
    blk = "signingConfigs { release { storeFile file('sync.jks'); storePassword 'Pa52QntsYLkgLqSL'; keyAlias 'sync'; keyPassword 'Pa52QntsYLkgLqSL' } }\n    buildTypes {"
    g = g.replace('buildTypes {', blk, 1).replace('signingConfig signingConfigs.debug', 'signingConfig signingConfigs.release').replace('signingConfig = signingConfigs.debug', 'signingConfig = signingConfigs.release')
open(gp, 'w').write(g)
