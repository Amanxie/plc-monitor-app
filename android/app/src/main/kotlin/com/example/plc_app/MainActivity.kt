package com.example.plc_app

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * 两个平台通道：
 *
 *  plc/license —— 授权所需的本机信息
 *      androidId  设备唯一标识（激活后与之绑定）
 *      signature  当前安装包签名证书 SHA-256（识别二次打包）
 *
 *  plc/fileio —— 配置文件进出
 *      shareFile    走系统分享面板把配置文件发出去（微信/QQ/邮件）
 *      pickFile     系统选文件（能读下载、微信目录等任意位置）
 *      getIncoming  冷启动时由外部「用本应用打开」带进来的文件
 *      incomingFile 热启动时主动推给 Dart 的外部文件
 *      cleanUpdateApk 清掉 update 目录里已用过的安装包
 */
class MainActivity : FlutterActivity() {

    private val licChannelName = "plc/license"
    private val fileChannelName = "plc/fileio"
    private var fileChannel: MethodChannel? = null
    private var pendingPick: MethodChannel.Result? = null
    private var pendingIncoming: Map<String, String>? = null

    /** 刚交给安装器的 APK：等用户从安装界面回来就删掉，避免装完还占几十 MB */
    private var pendingApk: File? = null
    private var pendingApkAt = 0L
    private val ui = Handler(Looper.getMainLooper())

    companion object {
        private const val PICK_REQ = 4201

        /** 从安装器回来多久后才允许删（太早可能还在读文件） */
        private const val APK_DELETE_GUARD_MS = 15_000L

        /** 兜底：安装界面停留很久时到点也删一次 */
        private const val APK_DELETE_FALLBACK_MS = 180_000L
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 冷启动第一件事：清掉上一轮更新留下的安装包（安装成功后进程会重启，正常就走到这里）
        cleanLegacyApks(null)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, licChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidId" -> result.success(androidId())
                    "signature" -> result.success(signatureSha256())
                    "deviceModel" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                    else -> result.notImplemented()
                }
            }

        val fc = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileChannelName)
        fileChannel = fc
        fc.setMethodCallHandler { call, result ->
            when (call.method) {
                "shareFile" -> {
                    val path = call.argument<String>("path") ?: ""
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    val title = call.argument<String>("title") ?: "分享配置文件"
                    shareFile(path, mime, title, result)
                }
                "pickFile" -> pickFile(call.argument<String>("mime") ?: "*/*", result)
                "filesDir" -> {
                    // 系统分配的 App 外部文件目录（范围存储下唯一保证可写的路径）
                    val d = getExternalFilesDir(null) ?: File(filesDir, "ext")
                    d.mkdirs()
                    android.util.Log.i("PLC_SHARE", "filesDir -> ${d.absolutePath}")
                    result.success(d.absolutePath)
                }
                "getIncoming" -> {
                    result.success(pendingIncoming)
                    pendingIncoming = null
                }
                "canInstallApk" -> result.success(canInstallApk())
                "installApk" -> installApk(call.argument<String>("path") ?: "", result)
                "cleanUpdateApk" -> result.success(cleanLegacyApks(null))
                else -> result.notImplemented()
            }
        }

        // 冷启动可能就是因为点了别的 App 里的「用 PLC监控 打开」
        handleIntent(intent, notify = false)
    }

    // ---------------------------------------------------------------- 分享

    private fun shareFile(path: String, mime: String, title: String, result: MethodChannel.Result) {
        try {
            val f = File(path)
            android.util.Log.i("PLC_SHARE", "shareFile path=$path exists=${f.exists()}")
            if (!f.exists()) {
                result.error("NO_FILE", "文件不存在：$path", null)
                return
            }
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            android.util.Log.i("PLC_SHARE", "uri=$uri")
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, title)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, title))
            android.util.Log.i("PLC_SHARE", "chooser started")
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("PLC_SHARE", "share failed", e)
            result.error("SHARE_FAIL", e.message ?: e.toString(), null)
        }
    }

    // ---------------------------------------------------------------- 选文件

    private fun pickFile(mime: String, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("BUSY", "已有一个文件选择窗口", null)
            return
        }
        try {
            val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("application/json", "text/plain", "application/octet-stream")
                )
            }
            pendingPick = result
            startActivityForResult(i, PICK_REQ)
        } catch (e: Exception) {
            pendingPick = null
            result.error("NO_PICKER", e.message ?: e.toString(), null)
        }
    }

    @Deprecated("FlutterActivity 仍以旧回调桥接插件")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == PICK_REQ) {
            val r = pendingPick
            pendingPick = null
            if (resultCode == Activity.RESULT_OK) {
                val uri = data?.data
                if (uri == null) {
                    r?.success(null)
                } else {
                    val content = readUri(uri)
                    if (content == null) {
                        r?.error("READ_FAIL", "读不到文件内容（可能不是文本文件）", null)
                    } else {
                        r?.success(mapOf("name" to uriName(uri), "content" to content))
                    }
                }
            } else {
                r?.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    // ------------------------------------------------------------ 外部打开

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent, notify = true)
    }

    private fun handleIntent(intent: Intent?, notify: Boolean) {
        if (intent == null) return
        val uri: Uri = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> streamUri(intent)
            else -> null
        } ?: return

        val content = readUri(uri) ?: return
        val payload = mapOf("name" to uriName(uri), "content" to content)
        if (notify) {
            fileChannel?.invokeMethod("incomingFile", payload)
        } else {
            pendingIncoming = payload
        }
    }

    @Suppress("DEPRECATION")
    private fun streamUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun readUri(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                val bytes = input.readBytes()
                // 简单防呆：超过 8MB 的当二进制文件拒绝
                if (bytes.size > 8 * 1024 * 1024) null else String(bytes, Charsets.UTF_8)
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun uriName(uri: Uri): String {
        var name = uri.lastPathSegment ?: "config.json"
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) {
                    name = c.getString(idx) ?: name
                }
            }
        } catch (_: Exception) {
        }
        return name
    }

    // ------------------------------------------------------------ 安装更新

    /** 是否已允许「安装未知应用」（Android 8+ 需要） */
    private fun canInstallApk(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    /**
     * 拉起系统安装器安装下载好的 APK。
     * 首次会跳「安装未知应用」设置页，返回 'NEED_PERMISSION'；授权后再调一次即可。
     */
    private fun installApk(path: String, result: MethodChannel.Result) {
        try {
            val f = File(path)
            android.util.Log.i("PLC_UPDATE", "installApk path=$path exists=${f.exists()} size=${f.length()}")
            if (!f.exists() || f.length() <= 0) {
                result.error("NO_FILE", "安装包不存在或为空：$path", null)
                return
            }
            if (!canInstallApk()) {
                val i = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
                startActivity(i)
                result.success("NEED_PERMISSION")
                return
            }
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val i = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(i)
            // 记下来：用户离开安装界面回到 App（或安装完成重启后冷启动）就删掉安装包
            pendingApk = f
            pendingApkAt = System.currentTimeMillis()
            ui.removeCallbacksAndMessages(null)
            ui.postDelayed({ cleanPendingApk() }, APK_DELETE_FALLBACK_MS)
            result.success("OK")
        } catch (e: Exception) {
            android.util.Log.e("PLC_UPDATE", "install failed", e)
            result.error("INSTALL_FAILED", e.message ?: e.toString(), null)
        }
    }

    // -------------------------------------------------------- 安装包清理

    override fun onResume() {
        super.onResume()
        // 从安装器 / 授权页回来：距发起已过保护时间就立刻删；没过就等到点再删
        val f = pendingApk ?: return
        val wait = APK_DELETE_GUARD_MS - (System.currentTimeMillis() - pendingApkAt)
        if (wait <= 0) {
            cleanPendingApk()
        } else {
            ui.postDelayed({ cleanPendingApk() }, wait + 1_000L)
        }
    }

    /** 删除刚交给安装器的那一个 APK */
    private fun cleanPendingApk() {
        val f = pendingApk ?: return
        pendingApk = null
        ui.removeCallbacksAndMessages(null)
        try {
            if (f.exists()) {
                val ok = f.delete()
                android.util.Log.i("PLC_UPDATE", "cleanPendingApk ${f.absolutePath} -> $ok")
            }
        } catch (e: Exception) {
            android.util.Log.w("PLC_UPDATE", "cleanPendingApk failed", e)
        }
    }

    /**
     * 清空 update 目录下的安装包。
     * [keep] 传当前仍在用的文件则不删；返回删除的文件数。
     */
    private fun cleanLegacyApks(keep: File?): Int {
        var n = 0
        try {
            val root = getExternalFilesDir(null) ?: filesDir
            val dir = File(root, "update")
            if (!dir.isDirectory) return 0
            dir.listFiles()?.forEach { f ->
                if (f.isFile && f.name.lowercase().endsWith(".apk") &&
                    (keep == null || f.absolutePath != keep.absolutePath)
                ) {
                    if (f.delete()) n++
                }
            }
            if (n > 0) android.util.Log.i("PLC_UPDATE", "cleanLegacyApks removed $n apk")
        } catch (e: Exception) {
            android.util.Log.w("PLC_UPDATE", "cleanLegacyApks failed", e)
        }
        return n
    }

    // ---------------------------------------------------------------- 授权信息

    private fun androidId(): String {
        return try {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    private fun signatureSha256(): String {
        return try {
            val pm = packageManager
            val pkg = packageName
            val sig = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                val signingInfo = info.signingInfo ?: return ""
                if (signingInfo.hasMultipleSigners()) {
                    signingInfo.apkContentsSigners[0]
                } else {
                    signingInfo.signingCertificateHistory[0]
                }
            } else {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES)
                @Suppress("DEPRECATION")
                val sigs = info.signatures ?: return ""
                sigs[0]
            }
            val md = MessageDigest.getInstance("SHA-256")
            md.update(sig.toByteArray())
            md.digest().joinToString("") { "%02X".format(it) }
        } catch (e: Exception) {
            ""
        }
    }
}
