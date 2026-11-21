package com.guoapp

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 海报兼容转码。
 *
 * 部分源站返回 HEIC/HEIF 封面，Flutter 的图片解码器不认这种格式，界面上只剩占位图。
 * 以前是「Go 取出 HEVC 裸流 → ffmpeg 转 JPEG」，ffmpeg 移除后改由系统 ImageDecoder
 * （API 28+ 原生支持 HEIF）就地转成 JPEG，不增加任何 so 体积。
 *
 * 转好的文件放在原图同级的 `compatible-v1/` 目录，按修改时间复用；只处理真正遇到
 * HEIC 的少数封面，调用失败时 Dart 侧直接退回原图，不影响其它格式。
 */
class CoverChannel(messenger: BinaryMessenger) {

    private val channel = MethodChannel(messenger, "duanju/cover")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "convert" -> {
                    val path = call.argument<String>("path") ?: ""
                    if (path.isEmpty()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        val converted = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                            null
                        } else {
                            runCatching { convert(File(path)) }.getOrNull()
                        }
                        main.post { result.success(converted) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    @RequiresApi(Build.VERSION_CODES.P)
    private fun convert(source: File): String? {
        if (!source.isFile || source.length() <= 0) return null
        val directory = File(source.parentFile, "compatible-v1").apply { mkdirs() }
        val target = File(directory, source.nameWithoutExtension + ".jpg")
        if (target.isFile && target.length() > 0) {
            target.setLastModified(System.currentTimeMillis())
            return target.path
        }
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) {
            decoder, info, _ ->
            // 海报只用于列表展示，交给软件位图并限制长边，避免 4K 封面占内存。
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val longest = max(info.size.width, info.size.height)
            if (longest > MAX_EDGE) {
                val scale = MAX_EDGE.toFloat() / longest
                decoder.setTargetSize(
                    (info.size.width * scale).roundToInt().coerceAtLeast(1),
                    (info.size.height * scale).roundToInt().coerceAtLeast(1),
                )
            }
        }
        try {
            FileOutputStream(target).use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) {
                    return null
                }
            }
        } finally {
            bitmap.recycle()
        }
        prune(directory)
        return target.path
    }

    /** 转码缓存不会因 Go 侧的海报清理而回收，自己限制一个上限。 */
    private fun prune(directory: File) {
        val files =
            directory.listFiles { file -> file.isFile && file.name.endsWith(".jpg") }
                ?: return
        if (files.size <= MAX_FILES) return
        files
            .sortedBy { it.lastModified() }
            .take(files.size - MAX_FILES)
            .forEach { it.delete() }
    }

    private companion object {
        const val MAX_EDGE = 1080
        const val MAX_FILES = 300
        const val JPEG_QUALITY = 90
    }
}
