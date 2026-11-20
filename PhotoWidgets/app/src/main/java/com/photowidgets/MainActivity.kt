package com.photowidgets

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    private val picker = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { picked ->
        if (picked.isEmpty()) return@registerForActivityResult
        picked.forEach { uri: Uri ->
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (e: SecurityException) {
                // Keep going; this photo may stop loading later.
            }
        }
        val all = (PhotoStore.list(this) + picked).distinct()
        PhotoStore.save(this, all)
        PhotoWidgetProvider.refreshAll(this)
        showStatus()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        findViewById<android.view.View>(R.id.choose).setOnClickListener { picker.launch(arrayOf("image/*")) }
        findViewById<android.view.View>(R.id.clear).setOnClickListener {
            PhotoStore.save(this, emptyList())
            PhotoWidgetProvider.refreshAll(this)
            showStatus()
        }
        showStatus()
    }

    private fun showStatus() {
        val n = PhotoStore.list(this).size
        findViewById<TextView>(R.id.status).text =
            if (n == 0) "No photos chosen yet." else "$n photo(s) in your widget."
    }
}
