package cn.wenxiang.wenxiang

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.core.content.ContextCompat

object NotificationIcons {
    fun largeIconBitmap(context: Context, sizePx: Int = 256): Bitmap {
        val drawable = ContextCompat.getDrawable(context, R.drawable.ic_notification_large)
            ?: ContextCompat.getDrawable(context, R.drawable.ic_launcher_foreground)!!
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, sizePx, sizePx)
        drawable.draw(canvas)
        return bitmap
    }
}
