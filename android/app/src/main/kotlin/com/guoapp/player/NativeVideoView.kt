package com.guoapp.player

import android.content.Context
import android.graphics.Color
import android.os.Build
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 承载两路 ExoPlayer 的原生视图。
 *
 * 两张 SurfaceView 从创建到销毁一直留在视图树里，各自终生绑一个播放器；
 * 切集只是把它们的 translationX 对调（见 [NativePlayerHost.applyVisibility]）。
 *
 * 视图本身交给 Flutter 的 Hybrid Composition 渲染，所以播放器实例与 Surface
 * 都不会因为 Flutter 重建而重建——这正是切集能瞬间完成的原因。
 */
class NativeVideoView(context: Context, private val host: NativePlayerHost) : PlatformView {

    private val container = FrameLayout(context)
    private val surfaces = arrayOf(SurfaceView(context), SurfaceView(context))

    /** 这次视图实例的标识：销毁时只解绑自己绑过的表面。 */
    private val token = Any()

    init {
        container.setBackgroundColor(Color.BLACK)
        surfaces.forEach { surface ->
            // 老系统上 SurfaceView 会被 Flutter 的合成层盖住，抬到媒体层才看得见；
            // 新系统 Hybrid Composition 会自己处理，抬上来反而会盖住弹幕和控件。
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.N_MR1) {
                surface.setZOrderMediaOverlay(true)
            }
            container.addView(surface, FrameLayout.LayoutParams(-1, -1))
        }
        host.bind(0, surfaces[0], token)
        host.bind(1, surfaces[1], token)
    }

    override fun getView(): View = container

    override fun dispose() {
        host.unbind(token)
        container.removeAllViews()
    }
}

class NativeVideoViewFactory(private val host: NativePlayerHost) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        NativeVideoView(context, host)

    companion object {
        const val VIEW_TYPE = "guoapp/native_video"
    }
}
