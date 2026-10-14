package io.eddayy.flutter_star_prnt

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Log
import android.webkit.URLUtil
import com.starmicronics.stario10.InterfaceType
import com.starmicronics.stario10.StarConnectionSettings
import com.starmicronics.stario10.StarDeviceDiscoveryManager
import com.starmicronics.stario10.StarDeviceDiscoveryManagerFactory
import com.starmicronics.stario10.StarPrinter
import com.starmicronics.stario10.starxpandcommand.DocumentBuilder
import com.starmicronics.stario10.starxpandcommand.DrawerBuilder
import com.starmicronics.stario10.starxpandcommand.MagnificationParameter
import com.starmicronics.stario10.starxpandcommand.PrinterBuilder
import com.starmicronics.stario10.starxpandcommand.StarXpandCommandBuilder
import com.starmicronics.stario10.starxpandcommand.drawer.Channel
import com.starmicronics.stario10.starxpandcommand.drawer.OpenParameter
import com.starmicronics.stario10.starxpandcommand.printer.Alignment
import com.starmicronics.stario10.starxpandcommand.printer.BarcodeParameter
import com.starmicronics.stario10.starxpandcommand.printer.BarcodeSymbology
import com.starmicronics.stario10.starxpandcommand.printer.CutType
import com.starmicronics.stario10.starxpandcommand.printer.FontType
import com.starmicronics.stario10.starxpandcommand.printer.ImageParameter
import com.starmicronics.stario10.starxpandcommand.printer.InternationalCharacterType
import com.starmicronics.stario10.starxpandcommand.printer.LogoParameter
import com.starmicronics.stario10.starxpandcommand.printer.QRCodeLevel
import com.starmicronics.stario10.starxpandcommand.printer.QRCodeModel
import com.starmicronics.stario10.starxpandcommand.printer.QRCodeParameter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL

/**
 * flutter_star_prnt_plus re-implemented on Star's StarXpand SDK (StarIO10).
 * Keeps the original MethodChannel contract ('flutter_star_prnt':
 * portDiscovery / checkStatus / print) so the Dart API is unchanged.
 */
class FlutterStarPrntPlugin : FlutterPlugin, MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private var discoveryManager: StarDeviceDiscoveryManager? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "flutter_star_prnt")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    discoveryManager?.stopDiscovery()
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "portDiscovery" -> portDiscovery(call.argument<String>("type") ?: "All", result)
      "checkStatus" -> checkStatus(call.argument<String>("portName") ?: "", result)
      "print" -> print(
          call.argument<String>("portName") ?: "",
          call.argument<List<Map<String, Any?>>>("printCommands") ?: emptyList(),
          result)
      else -> result.notImplemented()
    }
  }

  // ---------------------------------------------------------------- discovery

  private fun interfacesFor(type: String): List<InterfaceType> = when (type) {
    "LAN" -> listOf(InterfaceType.Lan)
    "Bluetooth" -> listOf(InterfaceType.Bluetooth, InterfaceType.BluetoothLE)
    "USB" -> listOf(InterfaceType.Usb)
    else -> listOf(InterfaceType.Lan, InterfaceType.Bluetooth, InterfaceType.BluetoothLE, InterfaceType.Usb)
  }

  private fun portPrefix(t: InterfaceType): String = when (t) {
    InterfaceType.Lan -> "TCP:"
    InterfaceType.Bluetooth -> "BT:"
    InterfaceType.BluetoothLE -> "BLE:"
    InterfaceType.Usb -> "USB:"
    else -> ""
  }

  private fun portDiscovery(type: String, result: Result) {
    val found = mutableListOf<Map<String, Any?>>()
    val main = Handler(Looper.getMainLooper())
    var replied = false
    fun reply() {
      if (replied) return
      replied = true
      main.post { result.success(found.toList()) }
    }

    val callback = object : StarDeviceDiscoveryManager.Callback {
      override fun onPrinterFound(printer: StarPrinter) {
        val s = printer.connectionSettings
        val info = printer.information
        val m = mutableMapOf<String, Any?>(
            "portName" to portPrefix(s.interfaceType) + s.identifier,
            "modelName" to (info?.model?.name ?: "Unknown"),
            "interfaceType" to s.interfaceType.name,
            "emulation" to info?.emulation?.name,
        )
        val mac = info?.detail?.lan?.macAddress ?: if (s.interfaceType == InterfaceType.Bluetooth) s.identifier else null
        if (mac != null) m["macAddress"] = mac
        info?.detail?.usb?.usbSerialNumber?.let { m["USBSerialNumber"] = it }
        synchronized(found) { found.add(m) }
      }

      override fun onDiscoveryFinished() = reply()
    }

    fun start(interfaces: List<InterfaceType>) {
      discoveryManager?.stopDiscovery()
      val manager = StarDeviceDiscoveryManagerFactory.create(interfaces, context)
      manager.discoveryTime = when {
        interfaces.contains(InterfaceType.BluetoothLE) -> 10_000
        interfaces.contains(InterfaceType.Lan) -> 5_000
        else -> 2_000
      }
      manager.callback = callback
      discoveryManager = manager
      manager.startDiscovery()
    }

    val wanted = interfacesFor(type)
    try {
      start(wanted)
    } catch (e: Exception) {
      // Typically missing Bluetooth runtime permission. Retry without Bluetooth for "All".
      val fallback = wanted.filter { it == InterfaceType.Lan || it == InterfaceType.Usb }
      if (fallback.isNotEmpty() && fallback.size != wanted.size) {
        try {
          Log.w(TAG, "Discovery failed (${e.message}), retrying with $fallback")
          start(fallback)
          return
        } catch (e2: Exception) {
          result.error("PORT_DISCOVERY_ERROR", e2.message, null)
          return
        }
      }
      result.error("PORT_DISCOVERY_ERROR", e.message, null)
    }
  }

  // --------------------------------------------------------------- connection

  private fun connectionSettings(portName: String): StarConnectionSettings {
    val idx = portName.indexOf(':')
    val prefix = if (idx > 0) portName.substring(0, idx).uppercase() else ""
    val rest = if (idx > 0) portName.substring(idx + 1) else portName
    return when (prefix) {
      "TCP", "LAN" -> StarConnectionSettings(InterfaceType.Lan, rest, true)
      "BT" -> StarConnectionSettings(InterfaceType.Bluetooth, rest, true)
      "BLE" -> StarConnectionSettings(InterfaceType.BluetoothLE, rest, true)
      "USB" -> StarConnectionSettings(InterfaceType.Usb, rest, true)
      // No/unknown prefix (e.g. a bare IP address): treat as LAN.
      else -> StarConnectionSettings(InterfaceType.Lan, portName, true)
    }
  }

  private fun checkStatus(portName: String, result: Result) {
    scope.launch {
      val printer = StarPrinter(connectionSettings(portName), context)
      val map = mutableMapOf<String, Any?>()
      try {
        printer.openAsync().await()
        val status = printer.getStatusAsync().await()
        map["is_success"] = true
        map["offline"] = false
        map["coverOpen"] = status.coverOpen
        map["receiptPaperEmpty"] = status.paperEmpty
        map["receiptPaperNearEmpty"] = status.paperNearEmpty
        map["cutterError"] = false
        map["overTemp"] = false
        map["hasError"] = status.hasError
        map["drawerOpenCloseSignal"] = status.drawerOpenCloseSignal
        map["ModelName"] = printer.information?.model?.name
      } catch (e: Exception) {
        map["is_success"] = false
        map["offline"] = true
        map["error_message"] = e.message ?: e.toString()
      } finally {
        try { printer.closeAsync().await() } catch (_: Exception) {}
      }
      result.success(map)
    }
  }

  private fun print(portName: String, commands: List<Map<String, Any?>>, result: Result) {
    scope.launch {
      val map = mutableMapOf<String, Any?>()
      val printer = StarPrinter(connectionSettings(portName), context)
      try {
        val job = withContext(Dispatchers.IO) { buildCommands(commands) }
        printer.openAsync().await()
        printer.printAsync(job).await()
        map["is_success"] = true
        map["offline"] = false
        map["info_message"] = "Success"
        try {
          val status = printer.getStatusAsync().await()
          map["coverOpen"] = status.coverOpen
          map["receiptPaperEmpty"] = status.paperEmpty
        } catch (_: Exception) {}
      } catch (e: Exception) {
        Log.e(TAG, "print failed", e)
        map["is_success"] = false
        map["offline"] = true
        map["error_message"] = e.message ?: e.toString()
      } finally {
        try { printer.closeAsync().await() } catch (_: Exception) {}
      }
      result.success(map)
    }
  }

  // ----------------------------------------------------------- command mapping

  /** Translates the legacy command list into a StarXpand command string. */
  private fun buildCommands(commands: List<Map<String, Any?>>): String {
    val document = DocumentBuilder()
    var printer = PrinterBuilder()
    var printerUsed = false
    fun flushPrinter() {
      if (printerUsed) document.addPrinter(printer)
      printer = PrinterBuilder()
      printerUsed = false
    }

    for (c in commands) {
      printerUsed = true
      when {
        c.containsKey("appendEncoding") || c.containsKey("appendCodePage") -> {
          // StarIO10 sends text as Unicode and picks the code page itself.
        }
        c.containsKey("appendCharacterSpace") -> printer.styleCharacterSpace(dotsToMm(c["appendCharacterSpace"]))
        c.containsKey("append") -> printText(printer, c["append"].toString(), c)
        c.containsKey("appendRaw") -> printText(printer, c["appendRaw"].toString(), c)
        c.containsKey("appendMultiple") -> {
          val w = int(c["width"], 2); val h = int(c["height"], 2)
          printer.add(PrinterBuilder().styleMagnification(MagnificationParameter(w, h))
              .actionPrintText(c["appendMultiple"].toString()))
        }
        c.containsKey("appendEmphasis") ->
          printer.add(PrinterBuilder().styleBold(true).actionPrintText(c["appendEmphasis"].toString()))
        c.containsKey("enableEmphasis") -> printer.styleBold(bool(c["enableEmphasis"], true))
        c.containsKey("appendInvert") ->
          printer.add(PrinterBuilder().styleInvert(true).actionPrintText(c["appendInvert"].toString()))
        c.containsKey("enableInvert") -> printer.styleInvert(bool(c["enableInvert"], true))
        c.containsKey("appendUnderline") ->
          printer.add(PrinterBuilder().styleUnderLine(true).actionPrintText(c["appendUnderline"].toString()))
        c.containsKey("enableUnderline") -> printer.styleUnderLine(bool(c["enableUnderline"], true))
        c.containsKey("appendInternational") -> international(c["appendInternational"].toString())?.let { printer.styleInternationalCharacter(it) }
        c.containsKey("appendLineFeed") -> printer.actionFeedLine(int(c["appendLineFeed"], 1))
        c.containsKey("appendUnitFeed") -> printer.actionFeed(dotsToMm(c["appendUnitFeed"]))
        c.containsKey("appendLineSpace") -> printer.styleLineSpace(dotsToMm(c["appendLineSpace"]))
        c.containsKey("appendFontStyle") -> printer.styleFont(if (c["appendFontStyle"].toString() == "B") FontType.B else FontType.A)
        c.containsKey("appendCutPaper") -> printer.actionCut(cutType(c["appendCutPaper"].toString()))
        c.containsKey("openCashDrawer") -> {
          flushPrinter()
          val ch = if (int(c["openCashDrawer"], 1) == 2) Channel.No2 else Channel.No1
          document.addDrawer(DrawerBuilder().actionOpen(OpenParameter().setChannel(ch)))
        }
        c.containsKey("appendBytes") || c.containsKey("appendRawBytes") -> {
          flushPrinter()
          val raw = c["appendBytes"] ?: c["appendRawBytes"]
          document.addRaw(toBytes(raw).toList())
        }
        c.containsKey("appendAbsolutePosition") -> {
          printer.styleHorizontalPositionTo(dotsToMm(c["appendAbsolutePosition"]))
          c["data"]?.let { printer.actionPrintText(it.toString()) }
        }
        c.containsKey("appendAlignment") -> {
          val a = alignment(c["appendAlignment"].toString())
          if (c["data"] != null) printer.add(PrinterBuilder().styleAlignment(a).actionPrintText(c["data"].toString()))
          else printer.styleAlignment(a)
        }
        c.containsKey("appendLogo") -> printer.actionPrintLogo(LogoParameter(c["appendLogo"].toString()))
        c.containsKey("appendBarcode") -> {
          val p = BarcodeParameter(c["appendBarcode"].toString(), barcodeSymbology(c["BarcodeSymbology"]?.toString()))
              .setPrintHri(bool(c["hri"], true))
              .setHeight(dotsToMm(c["height"] ?: 40))
          barcodeDots(c["BarcodeWidth"]?.toString())?.let { p.setBarDots(it) }
          withAlignment(printer, c) { it.actionPrintBarcode(p) }
        }
        c.containsKey("appendQrCode") -> {
          val p = QRCodeParameter(c["appendQrCode"].toString())
              .setModel(if (c["QrCodeModel"]?.toString() == "No1") QRCodeModel.Model1 else QRCodeModel.Model2)
              .setLevel(qrLevel(c["QrCodeLevel"]?.toString()))
              .setCellSize(int(c["cell"], 4))
          withAlignment(printer, c) { it.actionPrintQRCode(p) }
        }
        c.containsKey("appendBitmap") -> {
          val bmp = loadBitmap(c["appendBitmap"].toString())
          if (bmp != null) printImage(printer, bmp, c) else Log.e(TAG, "appendBitmap: could not load ${c["appendBitmap"]}")
        }
        c.containsKey("appendBitmapByteArray") -> {
          val bytes = toBytes(c["appendBitmapByteArray"])
          val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
          if (bmp != null) printImage(printer, bmp, c) else Log.e(TAG, "appendBitmapByteArray: could not decode image")
        }
        c.containsKey("appendBitmapText") -> {
          val fontSize = float(c["fontSize"], 25f)
          val width = int(c["width"], 576)
          val bmp = createBitmapFromText(c["appendBitmapText"].toString(), fontSize, width,
              Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL))
          printImage(printer, bmp, c)
        }
        else -> {
          Log.w(TAG, "Unsupported command ignored: ${c.keys}")
        }
      }
    }
    flushPrinter()
    return StarXpandCommandBuilder().addDocument(document).getCommands()
  }

  private fun printText(printer: PrinterBuilder, text: String, c: Map<String, Any?>) {
    if (c.containsKey("alignment")) {
      printer.add(PrinterBuilder().styleAlignment(alignment(c["alignment"].toString())).actionPrintText(text))
    } else {
      printer.actionPrintText(text)
    }
  }

  private fun withAlignment(printer: PrinterBuilder, c: Map<String, Any?>, block: (PrinterBuilder) -> Unit) {
    val sub = PrinterBuilder()
    if (c.containsKey("alignment")) sub.styleAlignment(alignment(c["alignment"].toString()))
    if (c.containsKey("absolutePosition")) sub.styleHorizontalPositionTo(dotsToMm(c["absolutePosition"]))
    block(sub)
    printer.add(sub)
  }

  private fun printImage(printer: PrinterBuilder, source: Bitmap, c: Map<String, Any?>) {
    val width = int(c["width"], 576)
    val bothScale = bool(c["bothScale"], true)
    val bmp = rotate(source, c["rotation"]?.toString())
    // StarIO10 always scales the image to `width`. bothScale=false (keep original size) is
    // emulated by not upscaling smaller images.
    val targetWidth = if (bothScale) width else minOf(width, bmp.width)
    val param = ImageParameter(bmp, targetWidth).setEffectDiffusion(bool(c["diffusion"], true))
    withAlignment(printer, c) { it.actionPrintImage(param) }
  }

  private fun rotate(bmp: Bitmap, rotation: String?): Bitmap {
    val deg = when (rotation) { "Left90" -> 270f; "Right90" -> 90f; "Rotate180" -> 180f; else -> return bmp }
    val m = Matrix().apply { postRotate(deg) }
    return Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
  }

  private fun loadBitmap(path: String): Bitmap? = try {
    if (URLUtil.isValidUrl(path) && (path.startsWith("http://") || path.startsWith("https://"))) {
      URL(path).openStream().use { BitmapFactory.decodeStream(it) }
    } else {
      BitmapFactory.decodeFile(path.removePrefix("file://"))
    }
  } catch (e: Exception) {
    Log.e(TAG, "loadBitmap failed", e); null
  }

  private fun createBitmapFromText(text: String, textSize: Float, printWidth: Int, typeface: Typeface): Bitmap {
    val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
      this.textSize = textSize
      this.typeface = typeface
      color = Color.BLACK
    }
    val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, printWidth)
        .setAlignment(Layout.Alignment.ALIGN_NORMAL)
        .setLineSpacing(0f, 1f)
        .setIncludePad(false)
        .build()
    val bitmap = Bitmap.createBitmap(layout.width, maxOf(1, layout.height), Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.WHITE)
    layout.draw(canvas)
    return bitmap
  }

  // ------------------------------------------------------------------ helpers

  /** Legacy API used printer dots (203 dpi ≈ 8 dots/mm); StarIO10 uses millimetres. */
  private fun dotsToMm(v: Any?): Double = (v?.toString()?.toDoubleOrNull() ?: 0.0) / 8.0

  private fun int(v: Any?, def: Int) = v?.toString()?.toDoubleOrNull()?.toInt() ?: def
  private fun float(v: Any?, def: Float) = v?.toString()?.toFloatOrNull() ?: def
  private fun bool(v: Any?, def: Boolean) = v?.toString()?.toBooleanStrictOrNull() ?: def

  private fun toBytes(v: Any?): ByteArray = when (v) {
    is ByteArray -> v
    is List<*> -> ByteArray(v.size) { i -> (v[i] as Number).toByte() }
    is IntArray -> ByteArray(v.size) { i -> v[i].toByte() }
    null -> ByteArray(0)
    else -> v.toString().toByteArray(Charsets.UTF_8)
  }

  private fun alignment(s: String) = when (s) { "Center" -> Alignment.Center; "Right" -> Alignment.Right; else -> Alignment.Left }

  private fun cutType(s: String) = when (s) {
    "FullCut" -> CutType.FullDirect
    "PartialCut" -> CutType.PartialDirect
    "PartialCutWithFeed" -> CutType.Partial
    else -> CutType.Full // FullCutWithFeed
  }

  private fun international(s: String): InternationalCharacterType? = when (s) {
    "UK" -> InternationalCharacterType.UK
    "USA" -> InternationalCharacterType.Usa
    "France" -> InternationalCharacterType.France
    "Germany" -> InternationalCharacterType.Germany
    "Denmark" -> InternationalCharacterType.Denmark
    "Sweden" -> InternationalCharacterType.Sweden
    "Italy" -> InternationalCharacterType.Italy
    "Spain" -> InternationalCharacterType.Spain
    "Japan" -> InternationalCharacterType.Japan
    "Norway" -> InternationalCharacterType.Norway
    "Denmark2" -> InternationalCharacterType.Denmark2
    "Spain2" -> InternationalCharacterType.Spain2
    "LatinAmerica" -> InternationalCharacterType.LatinAmerica
    "Korea" -> InternationalCharacterType.Korea
    "Ireland" -> InternationalCharacterType.Ireland
    "Legal" -> InternationalCharacterType.Legal
    else -> null
  }

  private fun barcodeSymbology(s: String?) = when (s) {
    "Code39" -> BarcodeSymbology.Code39
    "Code93" -> BarcodeSymbology.Code93
    "ITF" -> BarcodeSymbology.Itf
    "JAN8" -> BarcodeSymbology.Jan8
    "JAN13" -> BarcodeSymbology.Jan13
    "NW7" -> BarcodeSymbology.NW7
    "UPCA" -> BarcodeSymbology.UpcA
    "UPCE" -> BarcodeSymbology.UpcE
    else -> BarcodeSymbology.Code128
  }

  private fun barcodeDots(s: String?): Int? = s?.removePrefix("Mode")?.toIntOrNull()?.let { ((it - 1) % 3) + 1 }

  private fun qrLevel(s: String?) = when (s) { "H" -> QRCodeLevel.H; "M" -> QRCodeLevel.M; "Q" -> QRCodeLevel.Q; else -> QRCodeLevel.L }

  companion object {
    private const val TAG = "FlutterStarPrnt"
  }
}
