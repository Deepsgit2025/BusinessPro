package com.businesspro.app

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channel = "com.businesspro.app/whatsapp"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendImageToNumber" -> {
                        val path = call.argument<String>("path")
                        val phone = call.argument<String>("phone")
                        val caption = call.argument<String>("caption")
                        result.success(sendImageToNumber(path, phone, caption))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Opens WhatsApp directly in the chat for [phone] with the image at [path]
     * attached and [caption] pre-filled, so the user only taps Send.
     *
     * Returns true if WhatsApp was launched. Returns false (so Dart can fall
     * back to the generic share sheet) if the file is missing, the number is
     * empty, or WhatsApp cannot resolve the intent.
     */
    private fun sendImageToNumber(path: String?, phone: String?, caption: String?): Boolean {
        if (path.isNullOrEmpty() || phone.isNullOrEmpty()) return false
        val file = File(path)
        if (!file.exists()) return false

        return try {
            val uri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.whatsapp.fileprovider",
                file,
            )

            // jid = "<digits>@s.whatsapp.net" targets the exact chat. The number
            // must be digits only with country code (Dart normalises this).
            val jid = "${phone.filter { it.isDigit() }}@s.whatsapp.net"

            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                if (!caption.isNullOrEmpty()) putExtra(Intent.EXTRA_TEXT, caption)
                putExtra("jid", jid)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                // Prefer the standard WhatsApp; fall back to Business below.
                setPackage("com.whatsapp")
            }

            // If consumer WhatsApp isn't installed, try WhatsApp Business.
            if (intent.resolveActivity(packageManager) == null) {
                intent.setPackage("com.whatsapp.w4b")
            }
            if (intent.resolveActivity(packageManager) == null) return false

            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
