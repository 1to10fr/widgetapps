package com.photowidgets

import android.content.Context
import android.net.Uri

object PhotoStore {
    private const val PREFS = "photos"
    private const val KEY_URIS = "uris"
    private const val KEY_INDEX = "index"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun list(ctx: Context): List<Uri> =
        prefs(ctx).getString(KEY_URIS, "").orEmpty()
            .split("\n").filter { it.isNotBlank() }.map { Uri.parse(it) }

    fun save(ctx: Context, uris: List<Uri>) {
        prefs(ctx).edit()
            .putString(KEY_URIS, uris.joinToString("\n") { it.toString() })
            .putInt(KEY_INDEX, 0)
            .apply()
    }

    fun currentIndex(ctx: Context): Int = prefs(ctx).getInt(KEY_INDEX, 0)

    fun advance(ctx: Context) {
        val n = list(ctx).size
        if (n == 0) return
        prefs(ctx).edit().putInt(KEY_INDEX, (currentIndex(ctx) + 1) % n).apply()
    }
}
