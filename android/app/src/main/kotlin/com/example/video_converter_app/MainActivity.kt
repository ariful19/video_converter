package com.example.video_converter_app

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val channelName = "video_converter/platform"
    private val pickVideoRequestCode = 4117
    private val pickFolderRequestCode = 4118
    private val preferencesName = "video_converter_preferences"
    private val outputTreeUriKey = "output_tree_uri"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pickerExecutor = Executors.newSingleThreadExecutor()
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingFolderResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickVideoWithContext" -> launchVideoPicker(result)
                    "ensureOutputFolderAccess" -> ensureOutputFolderAccess(result)
                    "saveOutputToSourceFolder" -> saveOutputToSourceFolder(call, result)
                    "setKeepScreenOn" -> setKeepScreenOn(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun setKeepScreenOn(call: MethodCall, result: MethodChannel.Result) {
        val shouldKeepScreenOn = call.arguments as? Boolean ?: false
        runOnUiThread {
            if (shouldKeepScreenOn) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            result.success(null)
        }
    }

    private fun launchVideoPicker(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("pick_in_progress", "A video selection request is already active.", null)
            return
        }

        pendingPickResult = result
        val pickIntent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        startActivityForResult(pickIntent, pickVideoRequestCode)
    }

    private fun ensureOutputFolderAccess(result: MethodChannel.Result) {
        val persistedTreeUri = getPersistedTreeUri()
        if (persistedTreeUri != null && canUseTreeUri(persistedTreeUri)) {
            result.success(
                mapOf(
                    "treeUri" to persistedTreeUri.toString(),
                    "label" to resolveTreeLabel(persistedTreeUri),
                ),
            )
            return
        }

        if (pendingFolderResult != null) {
            result.error("folder_pick_in_progress", "Folder access request is already active.", null)
            return
        }

        pendingFolderResult = result
        val folderIntent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        startActivityForResult(folderIntent, pickFolderRequestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            pickVideoRequestCode -> handlePickVideoResult(resultCode, data)
            pickFolderRequestCode -> handleFolderResult(resultCode, data)
        }
    }

    private fun handlePickVideoResult(resultCode: Int, data: Intent?) {
        val result = pendingPickResult ?: return
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }

        val uri = data?.data
        if (uri == null) {
            result.error("pick_failed", "No video URI returned by Android picker.", null)
            return
        }

        val permissionFlags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (permissionFlags != 0) {
            try {
                contentResolver.takePersistableUriPermission(uri, permissionFlags)
            } catch (_: SecurityException) {
                // Not all providers support persisted grants; temporary access may still work.
            }
        }

        pickerExecutor.execute {
            try {
                val sourceContext = querySourceContext(uri)
                val inputPath = copyUriToCache(uri, sourceContext.displayName)
                postPickResult {
                    result.success(
                        mapOf(
                            "inputPath" to inputPath,
                            "displayName" to sourceContext.displayName,
                            "relativePath" to sourceContext.relativePath,
                        ),
                    )
                }
            } catch (error: Exception) {
                postPickResult {
                    result.error(
                        "pick_failed",
                        error.message
                            ?: "Failed to copy the selected video. Please check file permissions and available storage.",
                        null,
                    )
                }
            }
        }
    }

    private fun handleFolderResult(resultCode: Int, data: Intent?) {
        val result = pendingFolderResult ?: return
        pendingFolderResult = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }

        val treeUri = data?.data
        if (treeUri == null) {
            result.error("folder_pick_failed", "No folder URI returned by Android picker.", null)
            return
        }

        val requestedFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val grantedFlags = data.flags and requestedFlags
        if (grantedFlags != 0) {
            try {
                contentResolver.takePersistableUriPermission(treeUri, grantedFlags)
            } catch (_: SecurityException) {
                // Some providers may not support persistable grants.
            }
        }

        persistTreeUri(treeUri)
        result.success(
            mapOf(
                "treeUri" to treeUri.toString(),
                "label" to resolveTreeLabel(treeUri),
            ),
        )
    }

    private fun saveOutputToSourceFolder(call: MethodCall, result: MethodChannel.Result) {
        val tempOutputPath = call.argument<String>("tempOutputPath")
        val relativePath = normalizeRelativePath(call.argument<String>("relativePath"))
        val outputTreeUri = call.argument<String>("outputTreeUri")
        val requestedDisplayName = call.argument<String>("displayName")
        val displayName = sanitizeFileName(requestedDisplayName ?: "converted_video.mp4")

        if (tempOutputPath.isNullOrBlank()) {
            result.error("invalid_output", "Temp output path is missing.", null)
            return
        }
        if (relativePath.isNullOrBlank() && outputTreeUri.isNullOrBlank()) {
            result.error("missing_folder", "No writable output folder context available.", null)
            return
        }

        val tempFile = File(tempOutputPath)
        if (!tempFile.exists()) {
            result.error("missing_output", "Converted temp output file was not found.", null)
            return
        }

        try {
            when {
                !relativePath.isNullOrBlank() -> {
                    val saveResult = saveToMediaStore(tempFile, displayName, relativePath)
                    result.success(saveResult)
                }
                !outputTreeUri.isNullOrBlank() -> {
                    val saveResult = saveToTreeUri(tempFile, displayName, outputTreeUri)
                    result.success(saveResult)
                }
                else -> {
                    result.error("missing_folder", "No writable output folder context available.", null)
                }
            }
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    private fun saveToMediaStore(tempFile: File, displayName: String, relativePath: String): Map<String, String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IOException("Saving to MediaStore relative path requires Android 10 or newer.")
        }

        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, relativePath)
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val outputUri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Android MediaStore could not create output file.")

        try {
            resolver.openOutputStream(outputUri, "w")?.use { outputStream ->
                FileInputStream(tempFile).use { inputStream ->
                    inputStream.copyTo(outputStream)
                }
            } ?: throw IOException("Android MediaStore output stream is unavailable.")

            resolver.update(
                outputUri,
                ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) },
                null,
                null,
            )
        } catch (error: Exception) {
            resolver.delete(outputUri, null, null)
            throw error
        }

        return mapOf(
            "outputUri" to outputUri.toString(),
            "relativePath" to relativePath,
        )
    }

    private fun saveToTreeUri(tempFile: File, displayName: String, treeUriValue: String): Map<String, String> {
        val treeUri = Uri.parse(treeUriValue)
        val documentTree = DocumentFile.fromTreeUri(this, treeUri)
            ?: throw IOException("Selected output folder is not accessible.")
        if (!documentTree.canWrite()) {
            throw IOException("Selected output folder is not writable.")
        }

        documentTree.findFile(displayName)?.delete()
        val outputDocument = documentTree.createFile("video/mp4", displayName)
            ?: throw IOException("Could not create output file in selected folder.")

        contentResolver.openOutputStream(outputDocument.uri, "w")?.use { outputStream ->
            FileInputStream(tempFile).use { inputStream ->
                inputStream.copyTo(outputStream)
            }
        } ?: throw IOException("Selected folder output stream is unavailable.")

        return mapOf(
            "outputUri" to outputDocument.uri.toString(),
            "label" to (resolveTreeLabel(treeUri) ?: "selected folder"),
        )
    }

    private fun querySourceContext(uri: Uri): SourceContext {
        val projection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            arrayOf(OpenableColumns.DISPLAY_NAME, MediaStore.MediaColumns.RELATIVE_PATH)
        } else {
            arrayOf(OpenableColumns.DISPLAY_NAME)
        }

        var displayName = "video.mp4"
        var relativePath: String? = null

        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val displayNameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (displayNameIndex >= 0) {
                    displayName = sanitizeFileName(cursor.getString(displayNameIndex) ?: displayName)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val relativePathIndex = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                    if (relativePathIndex >= 0) {
                        relativePath = normalizeRelativePath(cursor.getString(relativePathIndex))
                    }
                }
            }
        }
        if (relativePath.isNullOrBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            relativePath = resolveRelativePathFromMediaDocument(uri)
        }

        return SourceContext(displayName = displayName, relativePath = relativePath)
    }

    private fun resolveRelativePathFromMediaDocument(uri: Uri): String? {
        if (!DocumentsContract.isDocumentUri(this, uri)) {
            return null
        }
        return try {
            val documentId = DocumentsContract.getDocumentId(uri)
            val parts = documentId.split(":")
            if (parts.size < 2 || parts[0] != "video") {
                return null
            }
            val mediaId = parts[1].toLongOrNull() ?: return null
            val mediaUri = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, mediaId)
            contentResolver.query(
                mediaUri,
                arrayOf(MediaStore.MediaColumns.RELATIVE_PATH),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                    if (index >= 0) {
                        return normalizeRelativePath(cursor.getString(index))
                    }
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun copyUriToCache(uri: Uri, displayName: String): String {
        val safeName = sanitizeFileName(displayName)
        val cacheFile = File(cacheDir, "picked_${System.currentTimeMillis()}_$safeName")
        try {
            contentResolver.openInputStream(uri)?.use { inputStream ->
                FileOutputStream(cacheFile).use { outputStream ->
                    inputStream.copyTo(outputStream)
                }
            } ?: throw IOException("Failed to open selected video stream.")
            return cacheFile.absolutePath
        } catch (error: Exception) {
            cacheFile.delete()
            throw error
        }
    }

    private fun sanitizeFileName(value: String): String {
        val cleaned = value.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
        return if (cleaned.isBlank()) "video.mp4" else cleaned
    }

    private fun normalizeRelativePath(value: String?): String? {
        val trimmed = value?.trim()?.replace('\\', '/') ?: return null
        if (trimmed.isBlank()) {
            return null
        }
        return if (trimmed.endsWith("/")) trimmed else "$trimmed/"
    }

    private fun getPersistedTreeUri(): Uri? {
        val uriValue = getSharedPreferences(preferencesName, MODE_PRIVATE)
            .getString(outputTreeUriKey, null)
            ?: return null
        return try {
            Uri.parse(uriValue)
        } catch (_: Exception) {
            null
        }
    }

    private fun persistTreeUri(uri: Uri) {
        getSharedPreferences(preferencesName, MODE_PRIVATE)
            .edit()
            .putString(outputTreeUriKey, uri.toString())
            .apply()
    }

    private fun canUseTreeUri(uri: Uri): Boolean {
        return try {
            val document = DocumentFile.fromTreeUri(this, uri)
            document != null && document.canWrite()
        } catch (_: Exception) {
            false
        }
    }

    private fun resolveTreeLabel(uri: Uri): String? {
        return try {
            DocumentFile.fromTreeUri(this, uri)?.name
        } catch (_: Exception) {
            null
        }
    }

    private fun postPickResult(action: () -> Unit) {
        if (isFinishing || isDestroyed) {
            return
        }
        mainHandler.post {
            if (isFinishing || isDestroyed) {
                return@post
            }
            action()
        }
    }

    override fun onDestroy() {
        pickerExecutor.shutdown()
        try {
            if (!pickerExecutor.awaitTermination(1, TimeUnit.SECONDS)) {
                pickerExecutor.shutdownNow()
            }
        } catch (_: InterruptedException) {
            pickerExecutor.shutdownNow()
            Thread.currentThread().interrupt()
        }
        super.onDestroy()
    }

}

data class SourceContext(
    val displayName: String,
    val relativePath: String?,
)
