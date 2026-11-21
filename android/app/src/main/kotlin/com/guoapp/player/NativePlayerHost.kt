package com.guoapp.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.SurfaceView
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import com.guoapp.player.DecoderPreference
import com.guoapp.player.PlaybackRenderersFactory

/**
 * 双 ExoPlayer 常驻宿主。
 *
 * 核心约定：每个播放器在创建（或首次绑定）时绑定自己的 SurfaceView，之后**任何路径
 * 都不再调用 setVideoSurfaceView**。切集只把两个 SurfaceView 的可视位置对调，
 * Surface 不销毁、MediaCodec 不 flush、也不需要等下一个关键帧。
 *
 * 之所以能做到，是因为两个 SurfaceView 从页面打开到关闭一直存在，备用那一路只是
 * 被移出可视区域（translationX），而不是 GONE —— GONE 会触发 Surface 销毁。
 */
@UnstableApi
class NativePlayerHost(private val context: Context) {

    fun interface Sink {
        fun emit(event: Map<String, Any?>)
    }

    var sink: Sink? = null

    private val handler = Handler(Looper.getMainLooper())
    private val players = arrayOfNulls<ExoPlayer>(2)
    private val surfaces = arrayOfNulls<SurfaceView>(2)

    /**
     * 每个槽位当前 SurfaceView 的持有者（一次平台视图实例）。
     *
     * 平台视图重建时 Flutter 可能先建新视图、再销毁旧视图：旧视图的 unbind 如果无条件
     * 清空，就会把新视图刚绑好的表面一起清掉，解码器从此没有出口，表现为有声音没画面。
     */
    private val tokens = arrayOfNulls<Any>(2)
    private var slot = 0

    /** 两路播放器各自累计读取的字节数，用于估算下载速率。 */
    private val bytesLoaded = LongArray(2)

    /**
     * 各槽位是否已渲染过真实首帧（借鉴 HongGuoTV 的三层就绪门槛）。
     * READY 只代表播放器管线就绪，不代表画面已经画出来；秒切必须以首帧为准。
     * 备用 Surface 挪出屏幕但未销毁，帧照常渲染，回调必然到达。
     */
    private val firstFrame = BooleanArray(2)

    /**
     * 两路统一缓冲参数：起播跑道 1.5s、上限 45s、目标 16MiB、时间优先。
     *
     * 旧方案（v2.0.15）按主/备角色在两套 DefaultLoadControl 之间翻转，但
     * media3 1.9 的 DefaultLoadControl 内部按 PlayerId 维护加载状态
     * （onPrepared 注册、shouldContinueLoading 里 checkNotNull 查表），翻转后
     * 回调会被转发到一套从未见过该 PlayerId 的内部实例，直接抛异常——表现为
     * 秒切备用后约 200ms 两条「Unexpected runtime error」，无感连播被自动
     * 恢复顶掉。两路统一参数后不再翻转：16MiB 时间优先既保证接管后有缓冲
     * 余量（跑道门槛 3s 依旧把就绪回执往后压），也同时限制双常驻播放器的
     * 内存与带宽占用。
     */
    private fun loadControl(): LoadControl =
        DefaultLoadControl.Builder()
            .setBufferDurationsMs(15_000, 45_000, 1_500, 4_000)
            .setTargetBufferBytes(20 * 1024 * 1024)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
    private var volume = 1f
    private var rate = 1f
    private var released = false
    private var polling = false

    private val poll = object : Runnable {
        override fun run() {
            if (released || !polling) return
            emitState()
            handler.postDelayed(this, 250L)
        }
    }

    // ---------------------------------------------------------------- 视图绑定

    /** 平台视图创建时把两个 SurfaceView 交给播放器，一个播放器一张，终生不变。 */
    fun bind(index: Int, surface: SurfaceView?, token: Any) {
        surfaces[index] = surface
        tokens[index] = token
        players[index]?.let { player ->
            if (surface != null) player.setVideoSurfaceView(surface) else player.clearVideoSurface()
        }
        applyVisibility()
    }

    /**
     * 平台视图销毁：只解绑**这块视图**自己绑过的表面。
     *
     * 不按 token 过滤的话，旧视图销毁时会把新视图已经绑好的表面清掉（Flutter 重建平台
     * 视图的顺序不保证先销毁后创建），之后播放器只出声音不出画面。
     */
    fun unbind(token: Any) {
        for (index in surfaces.indices) {
            if (tokens[index] !== token) continue
            players[index]?.clearVideoSurface()
            surfaces[index] = null
            tokens[index] = null
        }
    }

    private fun applyVisibility() {
        surfaces.forEachIndexed { index, surface ->
            surface ?: return@forEachIndexed
            // 备用那一路挪出可视区：Surface 仍然有效，解码器可以继续出帧。
            surface.translationX = if (index == slot) 0f else -10000f
        }
    }

    // ---------------------------------------------------------------- 播放器

    private fun ensure(index: Int): ExoPlayer {
        players[index]?.let { return it }
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(8_000)
            .setReadTimeoutMs(8_000)
        val loadControl = loadControl()
        val renderers = PlaybackRenderersFactory(context)
        DecoderPreference.applyTo(renderers)
        val player = ExoPlayer.Builder(context, renderers)
            .setMediaSourceFactory(
                DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http))
            )
            .setLoadControl(loadControl)
            .build()
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onLoadCompleted(
                eventTime: AnalyticsListener.EventTime,
                loadEventInfo: LoadEventInfo,
                mediaLoadData: MediaLoadData,
            ) {
                bytesLoaded[index] += loadEventInfo.bytesLoaded
            }

            override fun onRenderedFirstFrame(
                eventTime: AnalyticsListener.EventTime,
                output: Any,
                mediaDurationMs: Long,
            ) {
                firstFrame[index] = true
            }
        })
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) = emitState()

            override fun onIsPlayingChanged(isPlaying: Boolean) = emitState()

            override fun onPlayerError(error: PlaybackException) {
                sink?.emit(mapOf("type" to "error", "message" to (error.message ?: "播放失败")))
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width <= 0 || videoSize.height <= 0) return
                sink?.emit(
                    mapOf(
                        "type" to "videoSize",
                        "width" to videoSize.width,
                        "height" to videoSize.height,
                    )
                )
            }
        })
        surfaces[index]?.let { player.setVideoSurfaceView(it) }
        player.volume = if (index == slot) volume else 0f
        players[index] = player
        return player
    }

    private fun source(url: String, headers: Map<String, String>) = DefaultMediaSourceFactory(
        DefaultDataSource.Factory(
            context,
            DefaultHttpDataSource.Factory()
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(8_000)
                .setReadTimeoutMs(8_000)
                .setDefaultRequestProperties(headers),
        )
    ).createMediaSource(androidx.media3.common.MediaItem.fromUri(url))

    // ---------------------------------------------------------------- 指令

    fun open(url: String, headers: Map<String, String>, startMs: Long, play: Boolean) {
        if (released) return
        val player = ensure(slot)
        player.setMediaSource(source(url, headers))
        player.prepare()
        if (startMs > 0) player.seekTo(startMs)
        player.setPlaybackSpeed(rate)
        player.volume = volume
        player.playWhenReady = play
        startPolling()
        emitState()
    }

    /**
     * 预热下一集：只 prepare，不播；占用另一路已经绑好的 Surface。
     * 备用实例就绪（true）/出错或超时（false）时才回执，Dart 以此作为就绪信号。
     *
     * 就绪门槛（在 HongGuoTV 1.1.49 的 READY + 首帧 + 视频轨道三条件之上加一道）：
     * 起播跑道 ≥ 3s 才回执就绪。HongGuo 的接管条件只到 READY+首帧，起播跑道只有
     * bufferForPlaybackMs（1.5s），网络稍慢接管完就追网络——实测表现为接管后前 2 秒
     * 掉帧。暂停态的 ExoPlayer 会持续缓冲到 maxBuffer（18s），跑道门槛只是让回执
     * 晚到几百毫秒，换来接管即有缓冲余量。
     */
    fun preload(url: String, headers: Map<String, String>, startMs: Long, done: (Boolean) -> Unit) {
        // 不再设内存门槛：预热开关已交给用户控制（预加载关=永远单路），开着的
        // 设备宁可用内存换秒切体验。低内存设备上的表现由系统按需回收兜底。
        if (released) {
            done(false)
            return
        }
        val other = 1 - slot
        val player = ensure(other)
        player.stop()
        firstFrame[other] = false
        player.setMediaSource(source(url, headers))
        player.prepare()
        if (startMs > 0) player.seekTo(startMs)
        player.playWhenReady = false
        player.volume = 0f
        var settled = false
        var listener: Player.Listener? = null
        var check: Runnable? = null
        val timeout = Runnable {
            if (settled) return@Runnable
            settled = true
            check?.let { handler.removeCallbacks(it) }
            listener?.let { player.removeListener(it) }
            done(false)
        }
        fun finish(ready: Boolean) {
            if (settled) return
            settled = true
            handler.removeCallbacks(timeout)
            check?.let { handler.removeCallbacks(it) }
            listener?.let { player.removeListener(it) }
            done(ready)
        }
        listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_IDLE) finish(false)
            }

            override fun onPlayerError(error: PlaybackException) {
                finish(false)
            }
        }
        // 轮询就绪判定：READY/首帧/视频轨道/跑道四项齐备即回执。READY 之后缓冲
        // 继续增长不会再有状态回调，只能轮询；250ms 粒度足够。
        check = object : Runnable {
            override fun run() {
                if (settled) return
                val ready =
                    firstFrame[other] &&
                        player.playbackState == Player.STATE_READY &&
                        player.currentTracks.isTypeSelected(C.TRACK_TYPE_VIDEO) &&
                        player.bufferedPosition - player.currentPosition >= 3_000
                if (ready) {
                    finish(true)
                    return
                }
                handler.postDelayed(this, 250)
            }
        }
        player.addListener(listener)
        check?.let { handler.post(it) }
        handler.postDelayed(timeout, 8000)
    }

    /** 切集：不碰 Surface，只换谁在前面。备用实例没就绪时拒绝切换。 */
    fun swap(): Boolean {
        if (released) return false
        val next = 1 - slot
        val target = players[next] ?: return false
        // 备用还没 prepare 完（甚至预热刚开始）就换过去只会黑屏干等：
        // 宁可让当前这集继续播，等它就绪后再换。就绪以 READY + 真实首帧为准，
        // 只有 READY 没有首帧时切过去画面仍是黑的，同样不放行。
        if (target.playbackState != Player.STATE_READY || !firstFrame[next]) return false
        players[slot]?.let {
            it.volume = 0f
            it.playWhenReady = false
        }
        target.volume = volume
        target.playWhenReady = true
        slot = next
        applyVisibility()
        startPolling()
        emitState()
        return true
    }

    fun play() {
        // 门禁期间到达的 play 是旧会话的残余指令，忽略，避免退出后声音复播。
        if (released) return
        players[slot]?.playWhenReady = true
    }

    fun pause() {
        players[slot]?.playWhenReady = false
    }

    fun seek(positionMs: Long) {
        players[slot]?.seekTo(positionMs.coerceAtLeast(0L))
    }

    fun setRate(value: Float) {
        rate = value
        players[slot]?.setPlaybackSpeed(value)
    }

    fun setVolume(value: Float) {
        volume = value.coerceIn(0f, 1f)
        players[slot]?.volume = volume
    }

    fun stop() {
        // 直接操作每个实例：pause() 只看当前槽位，另一路会漏掉。
        players.forEach {
            it?.playWhenReady = false
            it?.seekTo(0)
        }
        stopPolling()
    }

    fun setDecoderMode(mode: String) {
        // 只影响之后新建的播放器实例，当前这一集下次打开时生效。
        DecoderPreference.softwareOnly = mode == "software"
        DecoderPreference.hardwareOnly = mode == "hardware"
    }

    fun state(): Map<String, Any?> = snapshot()

    /**
     * 当前活跃播放器累计读取的字节数。Dart 侧按时间差分估算下载速率，
     * 替代原来 mpv 的 `cache-speed` 属性。
     */
    fun bytesRead(): Long = bytesLoaded[slot]

    /**
     * 释放两个播放器实例并进入 released 门禁：此后到达的 open/preload/swap/play
     * 一律忽略——退出播放页后，任何还在路上的旧指令都不能凭空再造一个出声的
     * 播放器。宿主本身保持可用，新会话进来先调 [reset] 解除门禁。
     */
    fun release() {
        released = true
        stopPolling()
        players.forEach { it?.release() }
        players.fill(null)
        bytesLoaded.fill(0)
        slot = 0
        volume = 1f
        rate = 1f
    }

    /** 新会话开始：清掉上一轮残留并解除 released 门禁。 */
    fun reset() {
        released = false
        stopPolling()
        players.forEach { it?.release() }
        players.fill(null)
        bytesLoaded.fill(0)
        slot = 0
        volume = 1f
        rate = 1f
    }

    // ---------------------------------------------------------------- 状态上报

    private fun startPolling() {
        if (polling || released) return
        polling = true
        handler.post(poll)
    }

    private fun stopPolling() {
        polling = false
        handler.removeCallbacks(poll)
    }

    private fun emitState() {
        sink?.emit(snapshot())
    }

    private fun snapshot(): Map<String, Any?> {
        val player = players[slot] ?: return mapOf("type" to "state")
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L
        val buffered = player.bufferedPosition.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L
        val position = player.currentPosition.coerceAtLeast(0L)
        return mapOf(
            "type" to "state",
            "position" to position,
            "duration" to duration,
            "buffer" to buffered,
            "playing" to player.isPlaying,
            "buffering" to (player.playbackState == Player.STATE_BUFFERING),
            "completed" to (player.playbackState == Player.STATE_ENDED),
            "rate" to player.playbackParameters.speed.toDouble(),
            "volume" to (player.volume * 100f).toDouble(),
        )
    }
}
