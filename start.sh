#!/usr/bin/env bash
#
# start.sh
#
# This script creates a fresh React Native 0.72 project configured to work
# offline (no Metro bundler) and to communicate with a Python AOA USB server
# via Google's Android Open Accessory protocol.  It generates TypeScript
# boilerplate, configures Gradle and Android files, and sets up a Kotlin
# native module (`UsbAccessoryModule`) that wraps the Android USB Accessory
# APIs.  The resulting APK communicates with the server by sending and
# receiving newline-terminated messages.  A simple numeric keypad lets you
# enter POS/PIX machine numbers and credit amounts.

set -euo pipefail

APP_NAME="usb"
RN_VERSION="0.72.0"

say()  { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[err]\033[0m %s\n" "$*"; exit 1; }

say "Checando Java..."
java -version >/dev/null 2>&1 || die "Instale o JDK 17"
echo "Recomendado: JDK 17."

# Mate o servidor ADB para evitar conflitos com o modo 'accessory + adb'.
# Quando a depuração USB está ativada no dispositivo Android, ele usa o PID 0x2D01
# (accessory + adb).  O servidor adb do host pode abrir a interface ADB e
# interferir com o canal AOA, causando desconexões ENODEV.  Esta chamada mata
# o daemon adb, liberando a interface.  Você também pode desativar
# "Depuração USB" nas configurações do Android para que o dispositivo use
# 0x2D00 (accessory) e evite o ADB completamente.
if command -v adb >/dev/null 2>&1; then
  say "Finalizando daemon adb para evitar interferências..."
  adb kill-server || true
fi

# Remove existing project to start clean
if [ -d "${APP_NAME}" ]; then
  say "Removendo diretório existente ${APP_NAME}/ ..."
  rm -rf "${APP_NAME}"
fi

say "Criando projeto React Native ${RN_VERSION}..."
npx react-native@${RN_VERSION} init ${APP_NAME} --version ${RN_VERSION}

###############################################################################
# TypeScript setup
###############################################################################

# Install TypeScript and type definitions
install_ts() {
  npm i -D typescript @types/react @types/react-native @tsconfig/react-native
}

# Write a minimal tsconfig that extends the react-native template
write_tsconfig() {
  cat > tsconfig.json <<'JSON'
{
  "extends": "@tsconfig/react-native/tsconfig.json",
  "compilerOptions": {
    "skipLibCheck": true
  }
}
JSON
}

# Generate the main App.tsx file.  This file defines a simple UI that
# communicates with the native module.  Important: avoid rendering plain
# strings inside a <View>; wrap all text inside <Text> components.
write_app_tsx() {
  cat > App.tsx <<'TS'
// App.tsx
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Platform,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
  Alert,
  PermissionsAndroid,
  KeyboardAvoidingView,
} from 'react-native';
import { AOAUsbAccessory, aoaEmitter } from './UsbAccessory';

type AOAStatusEvent =
  | { type: 'connected'; details?: string }
  | { type: 'disconnected'; details?: string }
  | { type: 'permission'; granted: boolean; details?: string }
  | { type: 'error'; message: string };

type AOAUsbAccessoryModule = {
  open(options?: { manufacturer?: string; model?: string }): Promise<{
    manufacturer?: string; model?: string; serial?: string;
  } | null>;
  close(): Promise<void>;
  write(text: string): Promise<void>;
};

const pad2 = (n: number | string) => String(typeof n === 'number' ? n : parseInt(n || '0', 10)).padStart(2, '0');

const clampCredit = (v: string) => {
  let s = v.replace(/[^\d.,]/g, '');            // aceita , ou .
  s = s.replace(',', '.');                      // normaliza para ponto
  const parts = s.split('.');
  if (parts.length > 2) s = parts[0] + '.' + parts.slice(1).join('');
  if (s.length > 14) s = s.slice(0, 14);
  return s;
};

const makeMsg = (tipo: 'POS' | 'PIX', maquina: string, credito: string) => {
  const mm = pad2(maquina);
  const cc = credito.trim() === '' ? '0' : credito;
  return `${tipo};${mm};${cc}\n`;
};

const App: React.FC = () => {
  const [connected, setConnected] = useState(false);
  const [statusLine, setStatusLine] = useState('Desconectado');
  const [tipo, setTipo] = useState<'POS' | 'PIX'>('POS');
  const [machine, setMachine] = useState('01');
  const [credit, setCredit] = useState('0');
  const [logs, setLogs] = useState<string[]>([]);
  const logRef = useRef<ScrollView>(null);
  const lineBufferRef = useRef<string>('');
  const moduleReady = !!AOAUsbAccessory && !!aoaEmitter;

  const appendLog = useCallback((line: string) => {
    setLogs((prev) => {
      const next = [...prev, line];
      if (next.length > 200) next.shift();
      return next;
    });
    setTimeout(() => logRef.current?.scrollToEnd({ animated: true }), 50);
  }, []);

  useEffect(() => {
    if (!moduleReady) {
      appendLog('(!) Módulo nativo AOAUsbAccessory não encontrado.');
      return;
    }
    (async () => {
      try {
        if (Platform.OS === 'android' && Platform.Version >= 33) {
          try {
            const notif = await PermissionsAndroid.request(
              PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
            );
            if (notif !== PermissionsAndroid.RESULTS.GRANTED) {
              appendLog('Permissão de notificações negada; o serviço pode ser encerrado.');
            }
          } catch {}
        }
        await (AOAUsbAccessory as any)?.init?.();
      } catch {}
    })();

    const subs: { remove: () => void }[] = [];
    subs.push(
      aoaEmitter!.addListener('aoa-status', (evt: AOAStatusEvent) => {
        if (evt.type === 'connected') {
          setConnected(true); setStatusLine('Conectado');
          appendLog(`✓ AOA conectado${evt.details ? ` (${evt.details})` : ''}`);
        } else if (evt.type === 'disconnected') {
          setConnected(false); setStatusLine('Desconectado'); appendLog('⨯ AOA desconectado');
        } else if (evt.type === 'permission') {
          appendLog(evt.granted ? 'Permissão USB concedida' : 'Permissão USB negada');
        } else if (evt.type === 'error') {
          appendLog(`Erro AOA: ${evt.message}`);
        }
      })
    );
    subs.push(
      aoaEmitter!.addListener('aoa-data', (payload: { data?: string } | string) => {
        const chunk = typeof payload === 'string' ? payload : payload?.data ?? '';
        if (!chunk) return;
        lineBufferRef.current += chunk;
        let idx = lineBufferRef.current.indexOf('\n');
        while (idx >= 0) {
          const line = lineBufferRef.current.slice(0, idx).replace(/\r$/, '');
          lineBufferRef.current = lineBufferRef.current.slice(idx + 1);
          if (line.length > 0) {
            appendLog(`⇦ ${line}`);
            if (line.trim().toLowerCase() === 'pong') setStatusLine('Conectado (pong)');
          }
          idx = lineBufferRef.current.indexOf('\n');
        }
      })
    );
    return () => { subs.forEach((s) => s.remove()); };
  }, [moduleReady, appendLog]);

  const connect = useCallback(async () => {
    if (!moduleReady) { Alert.alert('AOA ausente', 'Módulo nativo AOAUsbAccessory não encontrado.'); return; }
    try {
      setStatusLine('Conectando...');
      const info = await AOAUsbAccessory!.open({ manufacturer: 'WEBSYS', model: 'RN-Pi-Link' });
      if (info && (info.manufacturer || info.model)) {
        setConnected(true); setStatusLine('Conectado');
        appendLog(`Conectado a ${info?.manufacturer ?? '-'} / ${info?.model ?? '-'} ${info?.serial ? `SN:${info.serial}` : ''}`);
      } else {
        setConnected(false); setStatusLine('Aguardando permissão');
        appendLog('Permissão USB solicitada. Conceda-a e toque Conectar novamente.');
      }
    } catch (e: any) {
      setConnected(false); setStatusLine('Desconectado'); appendLog(`Falha ao conectar: ${String(e?.message ?? e)}`);
    }
  }, [moduleReady, appendLog]);

  const disconnect = useCallback(async () => {
    if (!moduleReady) return;
    try { await AOAUsbAccessory!.close(); setConnected(false); setStatusLine('Desconectado'); appendLog('Conexão encerrada.'); }
    catch (e: any) { appendLog(`Erro ao desconectar: ${String(e?.message ?? e)}`); }
  }, [moduleReady, appendLog]);

  const writeLine = useCallback(async (line: string) => {
    if (!moduleReady) { Alert.alert('AOA ausente', 'Módulo nativo AOAUsbAccessory não encontrado.'); return; }
    try { await AOAUsbAccessory!.write(line); appendLog(`⇨ ${line.replace(/\n$/, '')}`); }
    catch (e: any) { appendLog(`Erro ao enviar: ${String(e?.message ?? e)}`); }
  }, [moduleReady, appendLog]);

  const onSend = useCallback(() => { writeLine(makeMsg(tipo, machine, credit)); }, [tipo, machine, credit, writeLine]);
  const onPing = useCallback(() => { writeLine('ping\n'); }, [writeLine]);

  const statusColor = connected ? '#1fbf75' : '#ff5c5c';

  return (
    <SafeAreaView style={styles.safe}>
      <KeyboardAvoidingView style={{flex: 1}} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={styles.container} keyboardShouldPersistTaps="handled">
          <View style={styles.header}>
            <Text style={styles.title}>AOA • POS/PIX</Text>
            <View style={[styles.statusPill, { backgroundColor: statusColor }]}>
              <Text style={styles.statusText}>{statusLine}</Text>
            </View>
          </View>

          <View style={styles.row}>
            <TouchableOpacity style={styles.btn} onPress={connect}><Text style={styles.btnText}>Conectar</Text></TouchableOpacity>
            <TouchableOpacity style={[styles.btn, styles.btnSecondary]} onPress={disconnect}><Text style={styles.btnText}>Desconectar</Text></TouchableOpacity>
            <TouchableOpacity style={[styles.btn, styles.btnGhost]} onPress={onPing}><Text style={styles.btnText}>Ping</Text></TouchableOpacity>
          </View>

          <View style={styles.row}>
            <TouchableOpacity style={[styles.tipoBtn, tipo === 'POS' && styles.tipoBtnActive]} onPress={() => setTipo('POS')}>
              <Text style={[styles.tipoBtnText, tipo === 'POS' && styles.tipoBtnTextActive]}>POS</Text>
            </TouchableOpacity>
            <TouchableOpacity style={[styles.tipoBtn, tipo === 'PIX' && styles.tipoBtnActive]} onPress={() => setTipo('PIX')}>
              <Text style={[styles.tipoBtnText, tipo === 'PIX' && styles.tipoBtnTextActive]}>PIX</Text>
            </TouchableOpacity>
          </View>

          <View style={styles.inputsRow}>
            <View style={[styles.inputWrap]}>
              <Text style={styles.label}>Máquina</Text>
              <TextInput
                style={styles.input}
                value={pad2(machine || '0')}
                onChangeText={(t) => setMachine((t.replace(/\D/g, '').slice(0, 2) || '0'))}
                placeholder="01"
                maxLength={2}
                // teclado nativo numérico
                keyboardType="number-pad"
                // Android 6: evita “full-screen extract”
                disableFullscreenUI={true}
                // UX
                autoCorrect={false}
                blurOnSubmit={true}
                returnKeyType="done"
                textAlign="center"
                importantForAutofill="no"
              />
            </View>

            <View style={[styles.inputWrap]}>
              <Text style={styles.label}>Crédito</Text>
              <TextInput
                style={styles.input}
                value={credit}
                onChangeText={(t) => setCredit(clampCredit(t))}
                placeholder="0"
                // teclado nativo decimal
                {...(Platform.OS === 'android'
                  ? { keyboardType: 'numeric' as const } // no Android antigo 'decimal-pad' pode não existir
                  : { keyboardType: 'decimal-pad' as const })}
                // se seu RN suportar inputMode, ajuda a pedir decimal:
                // inputMode="decimal"
                disableFullscreenUI={true}
                autoCorrect={false}
                blurOnSubmit={true}
                returnKeyType="done"
                textAlign="center"
                importantForAutofill="no"
              />
            </View>
          </View>

          <TouchableOpacity style={[styles.btn, styles.btnPrimary, { marginTop: 16 }]} onPress={onSend}>
            <Text style={styles.btnText}>Enviar</Text>
          </TouchableOpacity>

          <Text style={[styles.label, { marginTop: 16 }]}>Logs</Text>
          <View style={styles.logBox}>
            <ScrollView ref={logRef}>
              {logs.map((l, i) => (<Text key={i} style={styles.logLine}>{l}</Text>))}
            </ScrollView>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
};

export default App;

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: '#0f1115' },
  container: { flexGrow: 1, padding: 16, gap: 12 },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  title: { color: '#e6e6e6', fontSize: 20, fontWeight: '700' },
  statusPill: { paddingHorizontal: 12, paddingVertical: 6, borderRadius: 999 },
  statusText: { color: '#0f1115', fontWeight: '700' },
  row: { flexDirection: 'row', gap: 8, alignItems: 'center' },
  btn: { backgroundColor: '#2b2f3a', paddingVertical: 12, paddingHorizontal: 16, borderRadius: 8 },
  btnSecondary: { backgroundColor: '#3b4250' },
  btnGhost: { backgroundColor: '#20242e' },
  btnPrimary: { backgroundColor: '#345cff' },
  btnText: { color: '#e6e6e6', fontWeight: '700' },
  inputsRow: { flexDirection: 'row', gap: 12 },
  inputWrap: { flex: 1, backgroundColor: '#1a1e27', borderRadius: 10, padding: 10, borderWidth: 1, borderColor: '#252b37' },
  label: { color: '#a7b0c0', marginBottom: 6, fontSize: 13 },
  input: { color: '#e6e6e6', fontSize: 20, fontWeight: '700', padding: 0 },
  tipoBtn: { flex: 1, backgroundColor: '#1a1e27', paddingVertical: 12, borderRadius: 8, alignItems: 'center' },
  tipoBtnActive: { backgroundColor: '#345cff' },
  tipoBtnText: { color: '#a7b0c0', fontWeight: '700' },
  tipoBtnTextActive: { color: '#fff' },
  logBox: { flex: 1, backgroundColor: '#0c0e12', borderRadius: 10, padding: 10, borderWidth: 1, borderColor: '#252b37' },
  logLine: { color: '#9aa4b5', fontSize: 12, marginBottom: 4 },
});

TS
}

# Generate index.js to register the component
wire_index_js_to_tsx() {
  cat > index.js <<'JS'
import { AppRegistry } from 'react-native';
import App from './App';
import { name as appName } from './app.json';

AppRegistry.registerComponent(appName, () => App);
JS
}

###############################################################################
# Android configuration
###############################################################################

# After generating the project, navigate into it and set up TS
cd "${APP_NAME}"

say "Configurando TypeScript e arquivos de app..."
install_ts
write_tsconfig
write_app_tsx
wire_index_js_to_tsx

say "Ajustando Android (Hermes, tema AppCompat, USB, Gradle)..."

# Overwrite gradle.properties to enable Hermes and disable new architecture
cat > android/gradle.properties <<'PROPS'
org.gradle.jvmargs=-Xmx3g -Dfile.encoding=UTF-8
android.useAndroidX=true
android.enableJetifier=true
hermesEnabled=true
newArchEnabled=false
PROPS

# Simplified top-level build.gradle
cat > android/build.gradle <<'GRADLE'
buildscript {
    ext {
        buildToolsVersion = "33.0.2"
        minSdkVersion = 23
        compileSdkVersion = 33
        targetSdkVersion = 33
        kotlinVersion = "1.8.22"
    }
    repositories { google(); mavenCentral() }
    dependencies {
        classpath("com.android.tools.build:gradle:7.4.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.8.22")
    }
}
GRADLE

# Configure the Gradle wrapper to use 7.6
mkdir -p android/gradle/wrapper
cat > android/gradle/wrapper/gradle-wrapper.properties <<'PROPS'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-7.6-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
PROPS

# Settings for autolinking and using the react-native Gradle plugin
cat > android/settings.gradle <<'GRADLE'
pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
  includeBuild("../node_modules/@react-native/gradle-plugin")
}
dependencyResolutionManagement {
  repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
  repositories { google(); mavenCentral() }
}
rootProject.name = 'usb'
apply from: file("../node_modules/@react-native-community/cli-platform-android/native_modules.gradle");
applyNativeModulesSettingsGradle(settings)
include ':app'
GRADLE

# App-level build.gradle: configure Hermes, AppCompat, and include our native module
cat > android/app/build.gradle <<'GRADLE'
plugins {
    id "com.android.application"
    id "org.jetbrains.kotlin.android"
    id "com.facebook.react"
}
android {
    namespace "com.usbaccessory"
    compileSdkVersion rootProject.ext.compileSdkVersion

    defaultConfig {
        applicationId "com.usbaccessory"
        minSdkVersion rootProject.ext.minSdkVersion
        targetSdkVersion rootProject.ext.targetSdkVersion
        versionCode 1
        versionName "0.0.1"
    }

    buildTypes {
        debug { debuggable true }
        release {
            minifyEnabled false
            shrinkResources false
            proguardFiles getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro"
        }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_11
        targetCompatibility JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = "11" }

    buildFeatures { viewBinding true }
    packagingOptions {
        resources { excludes += ["META-INF/**"] }
        jniLibs   { pickFirsts += ["**/libc++_shared.so"] }
    }
}

dependencies {
    implementation fileTree(dir: "libs", include: ["*.jar"])
    implementation "com.facebook.react:react-android"
    implementation "com.facebook.react:hermes-android"
    implementation "androidx.appcompat:appcompat:1.6.1"
    implementation "androidx.swiperefreshlayout:swiperefreshlayout:1.1.0"
}
GRADLE

# Remove template source directories that might conflict
rm -rf android/app/src/debug || true
rm -rf android/app/src/release || true
rm -rf android/app/src/main/java/com/usb || true

# Write the AndroidManifest with a single normal activity, the invisible USB attach activity, and a foreground service
mkdir -p android/app/src/main/res/xml
cat > android/app/src/main/AndroidManifest.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-feature android:name="android.hardware.usb.accessory" android:required="false" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
    <!-- No Android 13+ (API 33), notificações são protegidas. Nossa
         UsbFgs precisa criar uma notificação de serviço em primeiro plano.
         Portanto, declare explicitamente POST_NOTIFICATIONS. O app deve
         solicitar essa permissão em tempo de execução quando necessário. -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <application
        android:name="com.usbaccessory.MainApplication"
        android:label="usb-rn-app"
        android:icon="@mipmap/ic_launcher"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:usesCleartextTraffic="true"
        android:extractNativeLibs="true"
        android:theme="@style/Theme.AppCompat.DayNight.NoActionBar">
        <!-- Foreground service to hold the USB connection alive -->
        <service
            android:name=".UsbFgs"
            android:exported="false"
            android:foregroundServiceType="connectedDevice" />
        <!-- Main RN activity -->
        <activity
            android:name="com.usbaccessory.MainActivity"
            android:exported="true"
            android:launchMode="singleTask"
            android:configChanges="keyboard|keyboardHidden|orientation|screenSize|screenLayout|uiMode">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <!-- Invisible activity that receives the USB accessory attach intent -->
        <activity
            android:name="com.usbaccessory.UsbAttachActivity"
            android:exported="true"
            android:theme="@android:style/Theme.NoDisplay">
            <intent-filter>
                <action android:name="android.hardware.usb.action.USB_ACCESSORY_ATTACHED" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
            <meta-data
                android:name="android.hardware.usb.action.USB_ACCESSORY_ATTACHED"
                android:resource="@xml/accessory_filter" />
        </activity>
    </application>
</manifest>
XML

# Provide the accessory filter matching our server's identification
cat > android/app/src/main/res/xml/accessory_filter.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
  <usb-accessory manufacturer="WEBSYS" model="RN-Pi-Link" version="1.0" />
</resources>
XML

# Create Java/Kotlin sources for MainActivity, UsbAttachActivity, MainApplication
mkdir -p android/app/src/main/java/com/usbaccessory

# MainActivity: simple RN activity, no auto-open to avoid duplicate opens
cat > android/app/src/main/java/com/usbaccessory/MainActivity.java <<'JAVA'
package com.usbaccessory;

import android.os.Bundle;
import android.view.WindowManager;
import com.facebook.react.ReactActivity;

public class MainActivity extends ReactActivity {

  @Override
  protected String getMainComponentName() {
    return "usb";
  }

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    // Mantém a tela sempre ligada enquanto esta Activity estiver em foco
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
  }
}

JAVA

# UsbAttachActivity: invisible activity triggered by USB_ACCESSORY_ATTACHED.  It launches
# the RN activity and opens the accessory via the native module.
cat > android/app/src/main/java/com/usbaccessory/UsbAttachActivity.java <<'JAVA'
package com.usbaccessory;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.Intent;
import android.hardware.usb.UsbAccessory;
import android.hardware.usb.UsbManager;
import android.os.Bundle;

public class UsbAttachActivity extends Activity {
  public static final String ACTION_USB_PERMISSION = "com.usbaccessory.USB_PERMISSION";
  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    // Launch MainActivity so that the RN app and module are alive
    Intent launch = new Intent(this, MainActivity.class)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    startActivity(launch);
    Intent intent = getIntent();
    if (intent != null && UsbManager.ACTION_USB_ACCESSORY_ATTACHED.equals(intent.getAction())) {
      UsbManager mgr = (UsbManager) getSystemService(USB_SERVICE);
      UsbAccessory acc = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY);
      if (mgr != null && acc != null) {
        if (mgr.hasPermission(acc)) {
          UsbAccessoryModule.tryAutoOpenStatic(this, acc);
        } else {
          PendingIntent pi = PendingIntent.getBroadcast(
              this, 0, new Intent(ACTION_USB_PERMISSION), PendingIntent.FLAG_IMMUTABLE);
          mgr.requestPermission(acc, pi);
        }
      }
    }
    finish();
  }
}
JAVA

# MainApplication: loads the bundled JS and registers our native package
cat > android/app/src/main/java/com/usbaccessory/MainApplication.java <<'JAVA'
package com.usbaccessory;

import android.app.Application;
import com.facebook.react.ReactApplication;
import com.facebook.react.ReactNativeHost;
import com.facebook.react.ReactPackage;
import com.facebook.react.shell.MainReactPackage;
import com.facebook.soloader.SoLoader;
import java.util.Arrays;
import java.util.List;

public class MainApplication extends Application implements ReactApplication {
  private final ReactNativeHost mReactNativeHost = new ReactNativeHost(this) {
    @Override
    public boolean getUseDeveloperSupport() {
      return false;
    }
    @Override
    protected String getBundleAssetName() { return "index.android.bundle"; }
    @Override
    protected List<ReactPackage> getPackages() {
      return Arrays.<ReactPackage>asList(
        new MainReactPackage(),
        new UsbAccessoryPackage()
      );
    }
    @Override
    protected String getJSMainModuleName() { return "index"; }
  };
  @Override
  public ReactNativeHost getReactNativeHost() { return mReactNativeHost; }
  @Override
  public void onCreate() {
    super.onCreate();
    SoLoader.init(this, false);
  }
}
JAVA

# Foreground service: holds the accessory connection open while the app is in the background
cat > android/app/src/main/java/com/usbaccessory/UsbFgs.kt <<'KOT'
package com.usbaccessory

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class UsbFgs : Service() {
  private val chanId = "aoa_connected"

  override fun onCreate() {
    super.onCreate()

    val nm = getSystemService(NotificationManager::class.java)

    // Em Android 8.0+ (API 26+) é obrigatório criar canal:
    if (Build.VERSION.SDK_INT >= 26) {
      val chan = NotificationChannel(
        chanId,
        "AOA conectado",
        NotificationManager.IMPORTANCE_LOW
      )
      nm.createNotificationChannel(chan)
    }

    val notif: Notification =
      if (Build.VERSION.SDK_INT >= 26) {
        NotificationCompat.Builder(this, chanId)
          .setSmallIcon(android.R.drawable.ic_dialog_info)
          .setContentTitle("Acessório USB conectado")
          .setContentText("Mantendo conexão ativa")
          .setOngoing(true)
          .build()
      } else {
        // Em API < 26 não existem canais, o construtor sem canal é aceito
        NotificationCompat.Builder(this)
          .setSmallIcon(android.R.drawable.ic_dialog_info)
          .setContentTitle("Acessório USB conectado")
          .setContentText("Mantendo conexão ativa")
          .setOngoing(true)
          .build()
      }

    // Iniciar como serviço em primeiro plano imediatamente
    startForeground(1001, notif)
  }

  override fun onStartCommand(i: Intent?, flags: Int, startId: Int): Int = START_STICKY

  override fun onBind(p0: Intent?): IBinder? = null
}

KOT

# Native module implementation.  Note: we removed listening for ACTION_USB_ACCESSORY_ATTACHED here
# because the attach activity handles that broadcast.  The module still listens for
# ACTION_USB_PERMISSION and ACTION_USB_ACCESSORY_DETACHED.
cat > android/app/src/main/java/com/usbaccessory/UsbAccessoryModule.kt <<'KOT'
package com.usbaccessory

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.ParcelFileDescriptor
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class UsbAccessoryModule(private val reactCtx: ReactApplicationContext)
  : ReactContextBaseJavaModule(reactCtx) {

  companion object {
    const val ACTION_USB_PERMISSION = "com.usbaccessory.USB_PERMISSION"
    @Volatile
    private var lastInstance: UsbAccessoryModule? = null

    @JvmStatic
    fun tryAutoOpenStatic(ctx: Context, acc: UsbAccessory) {
      val inst = lastInstance
      if (inst != null) {
        inst.tryAutoOpen(acc)
        return
      }
      val mgr = ctx.getSystemService(Context.USB_SERVICE) as UsbManager
      if (!mgr.hasPermission(acc)) {
        val pi = PendingIntent.getBroadcast(
          ctx, 0, Intent(ACTION_USB_PERMISSION), PendingIntent.FLAG_IMMUTABLE
        )
        mgr.requestPermission(acc, pi)
      }
    }
  }

  private var usbManager: UsbManager? = null
  private var pfd: ParcelFileDescriptor? = null
  private var input: BufferedInputStream? = null
  private var output: BufferedOutputStream? = null
  private var readThread: Thread? = null
  private val running = AtomicBoolean(false)
  private var pendingToOpen: UsbAccessory? = null

  private val receiver: BroadcastReceiver = object : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
      when (intent.action) {
        ACTION_USB_PERMISSION -> {
          @Suppress("DEPRECATION")
          val acc: UsbAccessory? = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
          val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
          if (acc != null && granted) {
            if (pendingToOpen != null && acc == pendingToOpen) pendingToOpen = null
            tryAutoOpen(acc)
          } else {
            sendStatus(type = "permission", granted = false, details = "negada")
          }
        }
        UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
          @Suppress("DEPRECATION")
          val acc: UsbAccessory? = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
          if (acc != null && pfd != null) {
            closeInternal()
            sendStatus(type = "disconnected")
          }
        }
      }
    }
  }

  init {
    lastInstance = this
    usbManager = reactCtx.getSystemService(Context.USB_SERVICE) as UsbManager
    val f = IntentFilter().apply {
      addAction(ACTION_USB_PERMISSION)
      addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
    }
    reactCtx.registerReceiver(receiver, f)
  }

  override fun getName() = "UsbAccessoryModule"

  override fun onCatalystInstanceDestroy() {
    try { closeInternal() } catch (_: Exception) {}
    try { reactCtx.unregisterReceiver(receiver) } catch (_: Exception) {}
    if (lastInstance === this) lastInstance = null
    super.onCatalystInstanceDestroy()
  }

  @ReactMethod
  fun init(promise: Promise) { promise.resolve(null) }

  @ReactMethod
  fun open(options: ReadableMap?, promise: Promise) {
    val wantManufacturer = options?.getString("manufacturer")
    val wantModel = options?.getString("model")
    val mgr = usbManager ?: (reactCtx.getSystemService(Context.USB_SERVICE) as UsbManager).also { usbManager = it }
    val list = mgr.accessoryList
    if (list == null || list.isEmpty()) {
      promise.reject("NO_ACCESSORY", "Nenhum accessory disponível")
      return
    }
    val acc = list.firstOrNull { a ->
      (wantManufacturer == null || a.manufacturer == wantManufacturer) &&
      (wantModel == null || a.model == wantModel)
    } ?: list[0]

    if (mgr.hasPermission(acc)) {
      val info = openAccessory(acc)
      promise.resolve(info)
    } else {
      val pi = PendingIntent.getBroadcast(
        reactCtx, 0, Intent(ACTION_USB_PERMISSION), PendingIntent.FLAG_IMMUTABLE
      )
      pendingToOpen = acc
      mgr.requestPermission(acc, pi)
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun write(msg: String, promise: Promise) {
    try {
      synchronized(this) {
        output?.write(msg.toByteArray())
        output?.flush()
      }
      promise.resolve(true)
    } catch (e: Exception) {
      promise.reject("WRITE_ERR", e)
    }
  }

  @ReactMethod
  fun close(promise: Promise) {
    try {
      closeInternal()
      sendStatus(type = "disconnected")
      promise.resolve(true)
    } catch (e: Exception) {
      promise.reject("CLOSE_ERR", e)
    }
  }

  fun tryAutoOpen(acc: UsbAccessory) {
    val mgr = usbManager ?: return
    if (pfd != null) return
    if (!mgr.hasPermission(acc)) {
      val pi = PendingIntent.getBroadcast(
        reactCtx, 0, Intent(ACTION_USB_PERMISSION), PendingIntent.FLAG_IMMUTABLE
      )
      pendingToOpen = acc
      mgr.requestPermission(acc, pi)
      return
    }
    openAccessory(acc)
  }

  private fun openAccessory(acc: UsbAccessory): WritableMap {
    closeInternal()
    val mgr = usbManager ?: throw IllegalStateException("UsbManager nulo")
    pfd = mgr.openAccessory(acc) ?: throw IOException("openAccessory() retornou nulo")
    val fd = pfd!!.fileDescriptor
    input  = BufferedInputStream(FileInputStream(fd))
    output = BufferedOutputStream(FileOutputStream(fd))
    startReader()

    // Iniciar serviço de foreground (compatível com API < 26)
    try {
      val i = Intent(reactCtx, UsbFgs::class.java)
      if (Build.VERSION.SDK_INT >= 26) {
        reactCtx.startForegroundService(i)
      } else {
        @Suppress("DEPRECATION")
        reactCtx.startService(i)
      }
    } catch (_: Exception) {}

    sendStatus(type = "connected", details = "${acc.manufacturer}/${acc.model}")
    return Arguments.createMap().apply {
      putString("manufacturer", acc.manufacturer)
      putString("model", acc.model)
      putString("serial", acc.serial)
    }
  }

  private fun startReader() {
    if (running.getAndSet(true)) return
    readThread = Thread {
      val buf = ByteArray(512)
      try {
        while (running.get()) {
          val n = input?.read(buf) ?: -1
          if (n <= 0) break
          val chunk = String(buf, 0, n, Charsets.UTF_8)
          sendEvent("aoa-data", Arguments.createMap().apply { putString("data", chunk) })
        }
      } catch (_: Exception) {
      } finally {
        running.set(false)
      }
    }.apply {
      isDaemon = true
      name = "AOA-Reader"
      start()
    }
  }

  private fun closeInternal() {
    running.set(false)
    try { readThread?.join(150) } catch (_: Exception) {}
    readThread = null
    try { input?.close() } catch (_: Exception) {}
    try { output?.close() } catch (_: Exception) {}
    try { pfd?.close() } catch (_: Exception) {}
    input = null; output = null; pfd = null
    try {
      val i = Intent(reactCtx, UsbFgs::class.java)
      reactCtx.stopService(i)
    } catch (_: Exception) {}
  }

  private fun sendStatus(type: String, details: String? = null, granted: Boolean? = null) {
    val map = Arguments.createMap().apply {
      putString("type", type)
      if (details != null) putString("details", details)
      if (granted != null) putBoolean("granted", granted)
    }
    sendEvent("aoa-status", map)
  }

  private fun sendEvent(name: String, params: WritableMap) {
    if (!reactCtx.hasActiveCatalystInstance()) return
    try {
      reactCtx.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
        .emit(name, params)
    } catch (_: Exception) {}
  }
}

KOT

# Register the native module via a package
cat > android/app/src/main/java/com/usbaccessory/UsbAccessoryPackage.kt <<'KOT'
package com.usbaccessory

import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ViewManager

class UsbAccessoryPackage : ReactPackage {
  override fun createNativeModules(reactContext: ReactApplicationContext): List<NativeModule> {
    return listOf(UsbAccessoryModule(reactContext))
  }
  override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> {
    return emptyList()
  }
}
KOT

# Provide a simple JS wrapper for the native module
cat > UsbAccessory.js <<'JS'
// UsbAccessory.js
import { NativeModules, NativeEventEmitter } from 'react-native';
const { UsbAccessoryModule } = NativeModules;
export const AOAUsbAccessory = UsbAccessoryModule;
export const aoaEmitter = UsbAccessoryModule
  ? new NativeEventEmitter(NativeModules.UsbAccessoryModule)
  : null;
JS

###############################################################################
# Bundle the JS for offline use
###############################################################################

say "Pré-empacotando bundle/ativos para rodar OFFLINE (sem Metro)..."
mkdir -p android/app/src/main/assets
mkdir -p android/app/src/main/res
rm -f android/app/src/main/assets/index.android.bundle || true

npx react-native bundle \
  --platform android \
  --dev false \
  --entry-file index.js \
  --bundle-output android/app/src/main/assets/index.android.bundle \
  --assets-dest android/app/src/main/res

###############################################################################
# Build the APK
###############################################################################

say "Build APK (debug offline)..."
cd android
./gradlew --stop >/dev/null 2>&1 || true
./gradlew clean >/dev/null
./gradlew assembleDebug

echo
echo "============================================================="
echo " APK gerado:"
echo "   $(pwd)/app/build/outputs/apk/debug/app-debug.apk"
echo " Para instalar via ADB:"
echo "   adb install -r app/build/outputs/apk/debug/app-debug.apk"
echo "============================================================="
