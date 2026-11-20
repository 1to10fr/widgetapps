package com.photowidgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import androidx.exifinterface.media.ExifInterface

class PhotoWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        PhotoStore.advance(context)
        ids.forEach { update(context, manager, it) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_NEXT) {
            PhotoStore.advance(context)
            refreshAll(context)
        } else {
            super.onReceive(context, intent)
        }
    }

    companion object {
        const val ACTION_NEXT = "com.photowidgets.NEXT"
        private const val MAX_SIDE = 700

        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, PhotoWidgetProvider::class.java))
            ids.forEach { update(context, manager, it) }
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_photo)

            val next = Intent(context, PhotoWidgetProvider::class.java).setAction(ACTION_NEXT)
            val pending = PendingIntent.getBroadcast(
                context, 0, next, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.root, pending)

            val uris = PhotoStore.list(context)
            var bitmap: Bitmap? = null
            if (uris.isNotEmpty()) {
                // Try the current photo; skip ones that can no longer be read.
                val start = PhotoStore.currentIndex(context) % uris.size
                for (i in uris.indices) {
                    bitmap = load(context, uris[(start + i) % uris.size])
                    if (bitmap != null) break
                }
            }
            if (bitmap != null) {
                views.setImageViewBitmap(R.id.photo, bitmap)
                views.setViewVisibility(R.id.photo, View.VISIBLE)
                views.setViewVisibility(R.id.empty, View.GONE)
            } else {
                views.setViewVisibility(R.id.photo, View.GONE)
                views.setViewVisibility(R.id.empty, View.VISIBLE)
            }
            manager.updateAppWidget(id, views)
        }

        private fun load(context: Context, uri: Uri): Bitmap? = try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (bounds.outWidth / sample > MAX_SIDE * 2 || bounds.outHeight / sample > MAX_SIDE * 2) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val decoded = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
            decoded?.let { fit(rotate(context, uri, it)) }
        } catch (e: Exception) {
            null
        }

        private fun rotate(context: Context, uri: Uri, src: Bitmap): Bitmap {
            val orientation = context.contentResolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            } ?: ExifInterface.ORIENTATION_NORMAL
            val degrees = when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> return src
            }
            val m = Matrix().apply { postRotate(degrees) }
            return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
        }

        private fun fit(src: Bitmap): Bitmap {
            val longest = maxOf(src.width, src.height)
            if (longest <= MAX_SIDE) return src
            val scale = MAX_SIDE.toFloat() / longest
            return Bitmap.createScaledBitmap(src, (src.width * scale).toInt(), (src.height * scale).toInt(), true)
        }
    }
}
