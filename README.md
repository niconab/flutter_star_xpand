# flutter_star_xpand (package `flutter_star_prnt_plus`)

Flutter plugin for Star Micronics receipt printers built on Star's **maintained** SDK,
[StarXpand / StarIO10](https://star-m.jp/products/s_print/sdk/starxpand/index.html):

* **iOS:** `StarIO10.xcframework` 2.14.0 (arm64 device, arm64 + x86_64 simulator, **no 32-bit slices**), from
  [StarXpand-SDK-iOS](https://github.com/star-micronics/StarXpand-SDK-iOS). It is **not** stored in this
  repo. With CocoaPods, the podspec downloads Star's official release archive
  (`github.com/star-micronics/StarXpand-SDK-iOS`, tag 2.14.0, SHA-256 verified) into
  `ios/flutter_star_prnt_plus/Frameworks/` on `pod install`. In Flutter's SPM mode, Star's Swift package is used directly.
  The build machine needs internet access to github.com.
* **Android:** `com.starmicronics:stario10:1.12.0` from Maven Central
  ([StarXpand-SDK-Android](https://github.com/star-micronics/StarXpand-SDK-Android)).
  Versions 1.13+ require `compileSdk 37`, so 1.12.0 is used for compatibility.

This replaces the unmaintained fork [niconab/flutter_star_prnt_plus](https://github.com/niconab/flutter_star_prnt_plus).
That fork shipped the old `StarIO.framework`/`StarIO_Extension.framework` fat binaries (armv7/i386, no arm64 simulator),
which current Xcode can't build.

**The Dart API is identical.** The package name is still `flutter_star_prnt_plus`, the import is still
`package:flutter_star_prnt_plus/flutter_star_prnt.dart`, and `StarPrnt`, `PrintCommands`, `PortInfo`,
`PrinterResponseStatus`, the enums and `StarMicronicsUtilities` are unchanged. Apps switch by changing only the git URL.

## Switching an app (e.g. TelmeGo)

```yaml
dependencies:
  flutter_star_prnt_plus:
    git:
      url: https://github.com/niconab/flutter_star_xpand.git
      ref: main
```

Then:

```bash
flutter clean
rm -rf ios/Pods ios/Podfile.lock
flutter pub get
cd ios && pod install --repo-update && cd ..
```

Requirements:
* iOS deployment target **15.0**. In `ios/Podfile`, use `platform :ios, '15.0'` or higher.
* Android `minSdkVersion` **26**, which StarIO10 requires. Set `minSdk = 26` in `android/app/build.gradle`.

## Usage (unchanged)

```dart
import 'package:flutter_star_prnt_plus/flutter_star_prnt.dart';

final ports = await StarPrnt.portDiscovery(StarPortType.All);
final port = ports.first;

final status = await StarPrnt.getStatus(portName: port.portName!, emulation: 'StarPRNT');

final cmds = PrintCommands()
  ..appendBitmapText(text: 'Hello World')
  ..push({'append': 'Plain text, åäö works (Unicode)\n'})
  ..appendCutPaper(StarCutPaperAction.PartialCutWithFeed);
final res = await StarPrnt.sendCommands(
    portName: port.portName!, emulation: 'StarPRNT', printCommands: cmds);
```

See `example/` for a full app.

## Port names

`portDiscovery` returns `portName` values with an interface prefix:

| Interface | portName example |
|---|---|
| LAN | `TCP:192.168.1.50` (identifier = IP or MAC, as found by StarIO10) |
| Bluetooth (classic / MFi) | `BT:00:11:62:xx:xx:xx` on Android, `BT:<serial>` on iOS |
| Bluetooth LE | `BLE:<identifier>` |
| USB | `USB:<serial>` |

A bare value with no prefix, such as `192.168.1.50`, is treated as LAN. Old `TCP:` and `BT:` port names saved by the
legacy plugin usually still work. Re-running discovery once is still recommended, because StarIO10 identifies some
printers differently, especially Bluetooth printers on iOS.

## How the legacy commands map onto StarIO10

The command list is translated into one `StarXpandCommandBuilder → DocumentBuilder → PrinterBuilder` job
(`DrawerBuilder` for the drawer, `addRaw` for raw bytes).

| Legacy command | StarIO10 |
|---|---|
| `append`, `appendRaw` (text) | `actionPrintText` (+ `styleAlignment` if `alignment` set) |
| `appendEmphasis` / `enableEmphasis` | `styleBold` |
| `appendInvert` / `enableInvert` | `styleInvert` |
| `appendUnderline` / `enableUnderline` | `styleUnderLine` |
| `appendMultiple` (width/height) | `styleMagnification` |
| `appendFontStyle` A/B | `styleFont` |
| `appendInternational` | `styleInternationalCharacter` |
| `appendCharacterSpace`, `appendLineSpace` | `styleCharacterSpace`, `styleLineSpace` (dots → mm, /8) |
| `appendLineFeed` | `actionFeedLine` |
| `appendUnitFeed` | `actionFeed` (dots → mm) |
| `appendAlignment` (+ optional `data`) | `styleAlignment` |
| `appendAbsolutePosition` (+ optional `data`) | `styleHorizontalPositionTo` (dots → mm) |
| `appendCutPaper` FullCut / FullCutWithFeed / PartialCut / PartialCutWithFeed | `actionCut` fullDirect / full / partialDirect / partial |
| `openCashDrawer` 1 / 2 | `DrawerBuilder.actionOpen` channel no1 / no2 |
| `appendBitmap` (file path or http(s) URL), `appendBitmapByteArray` / `appendBitmapByte`, `appendBitmapText` | `actionPrintImage` (diffusion → `setEffectDiffusion`, `width`, `alignment`, `absolutePosition`, `rotation`) |
| `appendBarcode` (+ `BarcodeSymbology`, `BarcodeWidth`, `height`, `hri`) | `actionPrintBarcode` |
| `appendQrCode` (+ `QrCodeModel`, `QrCodeLevel`, `cell`) | `actionPrintQRCode` |
| `appendLogo` | `actionPrintLogo(keyCode)` |
| `appendBytes`, `appendRawBytes` | `DocumentBuilder.addRaw` |

### Differences and old features with no StarIO10 equivalent

* **`emulation` is ignored.** StarIO10 detects the printer model and emulation automatically. The parameter is still
  accepted, so existing calls compile unchanged.
* **`appendEncoding` / `appendCodePage` are no-ops.** StarIO10 takes Unicode text and picks the code page itself, so
  Swedish characters (åäö) print correctly without them.
* **`appendBlackMark`** has no `PrinterBuilder` equivalent. In StarIO10 it is a document setting
  (`DocumentBuilder.settingBlackMark`), and it is ignored and logged here.
* **`appendHorizontalTabPosition`** is ignored. StarIO10's `styleHorizontalTabPositions` uses a different model.
* **`appendLogo`**: StarIO10 addresses stored logos by a key code string. The value is passed as a string, so logo `1`
  becomes key code `"1"`. `logoSize` is ignored.
* **`bothScale: false`**: StarIO10 always scales images to `width`. Here `false` means "don't upscale small images".
* **`BarcodeWidth` Mode1–9** is mapped to StarIO10 bar dots 1–3. Narrow/wide ratio levels aren't mapped.
* **Status fields:** `cutterError` and `overTemp` are always `false`, because StarIO10's basic status doesn't expose them.
  The response map also carries the extra keys `hasError`, `receiptPaperNearEmpty` and `drawerOpenCloseSignal`.
  `FirmwareVersion` is not returned.
* **`modelName`** is StarIO10's model name, e.g. `mCPrint3`, `tsp100IIIW`, `tsp100IV`, `mPOP`. These names no longer
  match the strings in `StarMicronicsUtilities.detectEmulation`, which may return `null`. Use a fallback such as
  `?.emulation ?? 'StarPRNT'`; the value is ignored anyway.
* **Barcode reader / `connect`** (commented out in the old plugin) is not implemented.
* Unknown commands are ignored and logged (`FlutterStarPrnt` tag in logcat / NSLog).

## iOS setup (Info.plist)

Add only the keys your printer interfaces need:

```xml
<!-- Bluetooth (MFi) and Lightning/USB printers -->
<key>UISupportedExternalAccessoryProtocols</key>
<array>
    <string>jp.star-m.starpro</string>
</array>
<!-- Bluetooth and Bluetooth LE printers -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Bluetooth is used to connect to the receipt printer.</string>
<!-- LAN printers (and discovery) -->
<key>NSLocalNetworkUsageDescription</key>
<string>The local network is used to find and connect to the receipt printer.</string>
```

An App Store app that talks to MFi printers over Bluetooth or USB needs Star's MFi approval. See
"Apple Approval Process for STAR MFi Applications" in Star's iOS README.

## Android setup

The plugin manifest already declares `INTERNET`, `ACCESS_NETWORK_STATE`, `BLUETOOTH`/`BLUETOOTH_ADMIN` and
`ACCESS_FINE_LOCATION` (≤ API 30), plus `BLUETOOTH_CONNECT` and `BLUETOOTH_SCAN` (neverForLocation).

* **Runtime:** on Android 12+ the app must request `BLUETOOTH_CONNECT` (and `BLUETOOTH_SCAN` for BLE) before
  discovery or printing over Bluetooth, for example with `permission_handler`. If the permission is missing,
  `portDiscovery(All)` falls back to LAN + USB only.
* **Android 17 / targetSdk 37 and up:** add the following and request it at runtime for LAN printers:
  ```xml
  <uses-permission android:name="android.permission.ACCESS_LOCAL_NETWORK" android:minSdkVersion="37" />
  ```
* **USB:** to avoid the permission dialog on every replug, add the intent filters and `device_filter.xml` /
  `accessory_filter.xml` described in Star's Android README, section 2.3.

## Licence note

This repository contains only our own code. The Dart code is MIT-licensed, inherited from flutter_star_prnt
(see `LICENSE`). Star's SDKs are **not** redistributed here: iOS StarIO10 is fetched from Star's official GitHub at
build time and Android StarIO10 from Maven Central. Both remain under Star Micronics' software licence, which the app
developer accepts by using them.
