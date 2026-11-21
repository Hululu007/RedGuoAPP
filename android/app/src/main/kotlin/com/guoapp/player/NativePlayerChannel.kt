package com.guoapp.player

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 原生播放内核的通道。
 *
 * 指令走 [METHOD]，状态回传走 [EVENT]；视频画面本身走 [NativeVideoViewFactory]
 * 注册的平台视图，不经过 Flutter 的纹理。
 */
object NativePlayerChannel {

    private const val METHOD = "duanju/player"
    private const val EVENT = "duanju/player/events"

    private var host: NativePlayerHost? = null
    private var eventSink: EventChannel.EventSink? = null

    fun attach(context: Context, engine: FlutterEngine) {
        val player = NativePlayerHost(context.applicationContext)
        player.sink = NativePlayerHost.Sink { event -> eventSink?.success(event) }
        host = player

        engine.platformViewsController.registry.registerViewFactory(
            NativeVideoViewFactory.VIEW_TYPE,
            NativeVideoViewFactory(player),
        )

        EventChannel(engine.dartExecutor.binaryMessenger, EVENT).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )

        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD).setMethodCallHandler { call, result ->
            val player = host
            if (player == null) {
                result.error("no_host", "原生播放器尚未初始化", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "open" -> {
                    player.open(
                        call.argument<String>("url") ?: "",
                        call.argument<Map<String, String>>("headers") ?: emptyMap(),
                        call.argument<Number>("startMs")?.toLong() ?: 0L,
                        call.argument<Boolean>("play") ?: true,
                    )
                    result.success(null)
                }
                "preload" -> {
                    // 备用实例就绪/失败后才回执，Dart 据此决定何时切换。
                    player.preload(
                        call.argument<String>("url") ?: "",
                        call.argument<Map<String, String>>("headers") ?: emptyMap(),
                        call.argument<Number>("startMs")?.toLong() ?: 0L,
                    ) { ready -> result.success(ready) }
                }
                "swap" -> result.success(player.swap())
                "play" -> {
                    player.play()
                    result.success(null)
                }
                "pause" -> {
                    player.pause()
                    result.success(null)
                }
                "seek" -> {
                    player.seek(call.argument<Number>("ms")?.toLong() ?: 0L)
                    result.success(null)
                }
                "setRate" -> {
                    player.setRate(call.argument<Number>("value")?.toFloat() ?: 1f)
                    result.success(null)
                }
                "setVolume" -> {
                    player.setVolume(call.argument<Number>("value")?.toFloat() ?: 1f)
                    result.success(null)
                }
                "stop" -> {
                    player.stop()
                    result.success(null)
                }
                "setDecoder" -> {
                    player.setDecoderMode(call.argument<String>("mode") ?: "optimized")
                    result.success(null)
                }
                "state" -> result.success(player.state())
                "reset" -> {
                    // 新会话的第一条指令：清残留、解除 released 门禁，并回快照。
                    player.reset()
                    result.success(player.state())
                }
                "bytesRead" -> result.success(player.bytesRead())
                "release" -> {
                    // 只释放两个播放器实例，宿主与平台视图工厂继续可用：
                    // 置空 host 会让第二次进入播放页的 open 直接返回 no_host。
                    player.release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun release() {
        host?.release()
        host = null
        eventSink = null
    }
}
