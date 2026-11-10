package com.fadseclab.fadocx

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfDocument
import android.util.Log
import org.libreoffice.kit.Document
import org.libreoffice.kit.LibreOfficeKit
import org.libreoffice.kit.Office
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer

class LOKitWrapper private constructor() {

    companion object {
        private const val TAG = "LOKitWrapper"
        private const val TWIPS_PER_INCH = 1440.0

        @Volatile
        private var instance: LOKitWrapper? = null
        private val instanceLock = Any()

        // Process-lifetime: LibreOfficeKit init() can only be called once.
        // Calling getLibreOfficeKitHandle() before init() causes a native SIGSEGV.
        @Volatile
        private var nativeInitialized = false

        fun getInstance(): LOKitWrapper {
            return instance ?: synchronized(instanceLock) {
                instance ?: LOKitWrapper().also { instance = it }
            }
        }
    }

    private var office: Office? = null
    private var document: Document? = null
    private val syncLock = Any()

    private fun writeSofficerc(dataDir: String, cacheDir: String) {
        val programDir = File(dataDir, "program")
        programDir.mkdirs()
        val userDir = File(cacheDir, "lo_user")
        userDir.mkdirs()

        File(programDir, "sofficerc").writeText("""[Bootstrap]
Logo=1
NativeProgress=1
URE_BOOTSTRAP=file:///assets/program/fundamentalrc
UserInstallation=file://$cacheDir/lo_user
""")
        Log.i(TAG, "Wrote sofficerc with UserInstallation=$userDir")
    }

    private fun setupRuntime(activity: Activity): Boolean {
        val dataDir = activity.applicationInfo.dataDir
        val cacheDir = activity.cacheDir.absolutePath
        val versionMarker = File(dataDir, ".lokit_version")
        val currentVersion = "v5"

        writeSofficerc(dataDir, cacheDir)
        if (versionMarker.exists() && versionMarker.readText() == currentVersion) {
            return true
        }

        Log.i(TAG, "Setting up LO runtime v$currentVersion ...")
        versionMarker.writeText(currentVersion)
        Log.i(TAG, "LO runtime setup complete")
        return true
    }

    fun init(activity: Activity): Boolean {
        synchronized(syncLock) {
            if (office != null) {
                Log.i(TAG, "LibreOfficeKit already initialized, skipping re-init")
                return true
            }
            try {
                if (!nativeInitialized) {
                    setupRuntime(activity)
                    LibreOfficeKit.putenv("SAL_LOG=+WARN+INFO")
                    LibreOfficeKit.putenv("SAL_LOK_OPTIONS=compact_fonts")
                    LibreOfficeKit.init(activity)
                    nativeInitialized = true
                    Log.i(TAG, "LibreOfficeKit native init completed (first time)")
                }
                val handle = LibreOfficeKit.getLibreOfficeKitHandle()
                if (handle == null) {
                    Log.e(TAG, "getLibreOfficeKitHandle returned null")
                    return false
                }
                office = Office(handle)
                Log.i(TAG, "LibreOfficeKit initialized (office created)")
                return true
            } catch (e: Exception) {
                Log.e(TAG, "LibreOfficeKit init failed", e)
                return false
            }
        }
    }

    fun loadDocument(path: String): Map<String, Any>? {
        synchronized(syncLock) {
            closeDocumentInternal()
            Log.i(TAG, "loadDocument: path=$path")
            Log.i(TAG, "loadDocument: office=${office != null}, fileExists=${java.io.File(path).exists()}")
            val doc = office?.documentLoad(path)
            if (doc == null) {
                val error = office?.error ?: "unknown"
                val officeNull = office == null
                Log.e(TAG, "Failed to load document: $error (officeNull=$officeNull, path=$path)")
                return null
            }
            doc.initializeForRendering()
            document = doc
            val typeName = when (doc.documentType) {
                Document.DOCTYPE_TEXT -> "TEXT"
                Document.DOCTYPE_SPREADSHEET -> "SPREADSHEET"
                Document.DOCTYPE_PRESENTATION -> "PRESENTATION"
                Document.DOCTYPE_DRAWING -> "DRAWING"
                else -> "OTHER"
            }
            val info = mapOf(
                "width" to doc.documentWidth,
                "height" to doc.documentHeight,
                "type" to doc.documentType,
                "typeName" to typeName,
                "parts" to doc.parts
            )
            Log.i(TAG, "Document loaded: $info")
            return info
        }
    }

    fun renderPage(part: Int, widthPx: Int, heightPx: Int): ByteArray? {
        synchronized(syncLock) {
            val doc = document ?: return null
            doc.setPart(part)
            val widthTwips = doc.documentWidth.toInt()
            val heightTwips = doc.documentHeight.toInt()
            return renderPageInternal(doc, widthPx, heightPx, widthTwips, heightTwips)
        }
    }

    fun getDocumentInfo(): Map<String, Any>? {
        synchronized(syncLock) {
            val doc = document ?: return null
            return mapOf(
                "width" to doc.documentWidth,
                "height" to doc.documentHeight,
                "type" to doc.documentType,
                "parts" to doc.parts
            )
        }
    }

    fun renderPageFit(part: Int, maxWidth: Int, maxHeight: Int): ByteArray? {
        synchronized(syncLock) {
            val doc = document ?: return null
            doc.setPart(part)
            val widthTwips = doc.documentWidth.toDouble()
            val heightTwips = doc.documentHeight.toDouble()
            if (widthTwips <= 0 || heightTwips <= 0) return null
            val ratio = minOf(maxWidth / widthTwips, maxHeight / heightTwips)
            val w = (widthTwips * ratio).toInt().coerceAtLeast(1)
            val h = (heightTwips * ratio).toInt().coerceAtLeast(1)
            return renderPageInternal(doc, w, h, widthTwips.toInt(), heightTwips.toInt())
        }
    }

    fun renderPageHighQuality(part: Int, maxWidth: Int, maxHeight: Int, scale: Float = 2.0f): ByteArray? {
        synchronized(syncLock) {
            val doc = document ?: return null
            doc.setPart(part)
            val widthTwips = doc.documentWidth.toDouble()
            val heightTwips = doc.documentHeight.toDouble()
            if (widthTwips <= 0 || heightTwips <= 0) return null
            val ratio = minOf(maxWidth / widthTwips, maxHeight / heightTwips) * scale
            val w = (widthTwips * ratio).toInt().coerceAtLeast(1)
            val h = (heightTwips * ratio).toInt().coerceAtLeast(1)
            return renderPageInternal(doc, w, h, widthTwips.toInt(), heightTwips.toInt())
        }
    }

    private fun renderPageInternal(doc: Document, widthPx: Int, heightPx: Int, twipW: Int, twipH: Int): ByteArray? {
        val buffer = ByteBuffer.allocateDirect(widthPx * heightPx * 4) ?: return null
        try {
            doc.paintTile(buffer, widthPx, heightPx, 0, 0, twipW, twipH)
            val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
            buffer.rewind()
            bitmap.copyPixelsFromBuffer(buffer)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
            bitmap.recycle()
            return stream.toByteArray()
        } catch (e: Exception) {
            Log.e(TAG, "Render failed", e)
            return null
        }
    }


    fun getPartPageRectangles(): String? {
        synchronized(syncLock) {
            val doc = document ?: return null
            return try { doc.partPageRectangles } catch (e: Exception) { null }
        }
    }

    fun getPageCount(): Int {
        synchronized(syncLock) {
            val doc = document ?: return 0
            val rects = try { doc.partPageRectangles } catch (e: Exception) { null } ?: return doc.parts
            if (doc.documentType == Document.DOCTYPE_TEXT) {
                return rects.trim().split("[,;\\s]+".toRegex()).size / 4
            }
            return doc.parts
        }
    }

    fun renderTextPage(pageIndex: Int, maxWidth: Int, maxHeight: Int, scale: Float): ByteArray? {
        synchronized(syncLock) {
            val doc = document ?: return null
            if (doc.documentType != Document.DOCTYPE_TEXT) return null
            try {
                val rects = doc.partPageRectangles ?: return null
                val tokens = rects.trim().split("[,;\\s]+".toRegex())
                if (tokens.size < (pageIndex + 1) * 4) return null
                val baseIdx = pageIndex * 4
                val pageX = tokens[baseIdx].toDouble().toInt()
                val pageY = tokens[baseIdx + 1].toDouble().toInt()
                val pageW = tokens[baseIdx + 2].toDouble().toInt()
                val pageH = tokens[baseIdx + 3].toDouble().toInt()
                if (pageW <= 0 || pageH <= 0) return null
                val ratio = minOf(maxWidth.toDouble() / pageW, maxHeight.toDouble() / pageH) * scale
                val renderW = (pageW * ratio).toInt().coerceAtLeast(1)
                val renderH = (pageH * ratio).toInt().coerceAtLeast(1)
                val buffer = ByteBuffer.allocateDirect(renderW * renderH * 4) ?: return null
                doc.paintTile(buffer, renderW, renderH, pageX, pageY, pageW, pageH)
                val bitmap = Bitmap.createBitmap(renderW, renderH, Bitmap.Config.ARGB_8888)
                buffer.rewind()
                bitmap.copyPixelsFromBuffer(buffer)
                val stream = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
                bitmap.recycle()
                return stream.toByteArray()
            } catch (e: Exception) {
                Log.e(TAG, "renderTextPage failed for page $pageIndex", e)
                return null
            }
        }
    }

    // [작동원리] 글꼴 문제 회피용: 각 페이지를 '그림 그리기(paintTile)'로 렌더링한 뒤
    // Android PdfDocument로 한 장씩 묶어 PDF를 만든다. (그리기 경로는 한글이 정상 표시됨)
    // 글 문서(Writer)는 페이지 사각형별로, 프레젠테이션은 슬라이드별로 그린다.
    // 반환: 만든 페이지 수(0이면 실패/미지원 → 호출측이 기존 PDF 내보내기로 대체).
    fun saveAsImagePdf(outPath: String): Int {
        synchronized(syncLock) {
            val doc = document ?: return 0
            val type = doc.documentType
            val pdf = PdfDocument()
            var made = 0
            try {
                val count = when (type) {
                    Document.DOCTYPE_TEXT -> getPageCount()
                    Document.DOCTYPE_PRESENTATION -> doc.parts
                    else -> 0
                }
                if (type == Document.DOCTYPE_SPREADSHEET) {
                    // [작동원리] 엑셀: 시트마다 '인쇄 페이지 영역'(있으면) 또는 A4 비율 조각으로 나눠
                    // 가로 1200px 그림으로 그려 PDF 페이지로 만든다(Word/PPT처럼 이어서 스크롤).
                    // 메모리 보호를 위해 한 장 최대 세로 1700px, 전체 최대 120페이지.
                    val wPx = 1200
                    for (sIdx in 0 until doc.parts) {
                        if (made >= 120) break
                        doc.setPart(sIdx)
                        val rects = ArrayList<IntArray>()
                        try {
                            val raw = doc.partPageRectangles
                            if (raw != null) {
                                val nums = Regex("-?\\d+").findAll(raw).map { it.value.toInt() }.toList()
                                var k = 0
                                while (k + 3 < nums.size) {
                                    if (nums[k + 2] > 0 && nums[k + 3] > 0) {
                                        rects.add(intArrayOf(nums[k], nums[k + 1], nums[k + 2], nums[k + 3]))
                                    }
                                    k += 4
                                }
                            }
                        } catch (e: Throwable) {
                            Log.w(TAG, "partPageRectangles unavailable", e)
                        }
                        if (rects.isEmpty()) {
                            val tw = doc.documentWidth.toInt()
                            val th = doc.documentHeight.toInt()
                            if (tw <= 0 || th <= 0) continue
                            val sliceTh = (tw * 1.4).toInt().coerceAtLeast(1)
                            var y = 0
                            while (y < th && rects.size < 40) {
                                rects.add(intArrayOf(0, y, tw, minOf(sliceTh, th - y)))
                                y += sliceTh
                            }
                        }
                        for (r in rects) {
                            if (made >= 120) break
                            val hPx = (wPx.toLong() * r[3] / r[2]).toInt().coerceIn(1, 1700)
                            val buffer = ByteBuffer.allocateDirect(wPx * hPx * 4)
                            doc.paintTile(buffer, wPx, hPx, r[0], r[1], r[2], r[3])
                            val bmp = Bitmap.createBitmap(wPx, hPx, Bitmap.Config.ARGB_8888)
                            buffer.rewind()
                            bmp.copyPixelsFromBuffer(buffer)
                            val pw = wPx / 2
                            val ph = (hPx / 2).coerceAtLeast(1)
                            val page = pdf.startPage(PdfDocument.PageInfo.Builder(pw, ph, made + 1).create())
                            page.canvas.drawBitmap(bmp, null, android.graphics.Rect(0, 0, pw, ph), android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG))
                            pdf.finishPage(page)
                            bmp.recycle()
                            made++
                        }
                    }
                }
                for (i in 0 until count) {
                    // 페이지 하나를 PNG 바이트로 그린다(가로 약 1400px 기준).
                    val bytes = (if (type == Document.DOCTYPE_TEXT) {
                        renderTextPage(i, 1400, 2000, 1.0f)
                    } else {
                        renderPageHighQuality(i, 1600, 1200, 1.0f)
                    }) ?: continue
                    val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: continue
                    // PDF 페이지 크기는 포인트 단위(px * 0.5 정도로 축소해 화면 비율 유지)
                    val pw = (bmp.width * 0.5f).toInt().coerceAtLeast(1)
                    val ph = (bmp.height * 0.5f).toInt().coerceAtLeast(1)
                    val page = pdf.startPage(PdfDocument.PageInfo.Builder(pw, ph, made + 1).create())
                    val dst = android.graphics.Rect(0, 0, pw, ph)
                    page.canvas.drawBitmap(bmp, null, dst, android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG))
                    pdf.finishPage(page)
                    bmp.recycle()
                    made++
                }
                if (made > 0) {
                    // 임시 파일에 쓴 뒤 이름을 바꿔, 중간에 끊겨도 깨진 PDF가 남지 않게 한다.
                    val tmp = File(outPath + ".tmp")
                    FileOutputStream(tmp).use { pdf.writeTo(it) }
                    File(outPath).delete()
                    if (!tmp.renameTo(File(outPath))) {
                        tmp.delete()
                        made = 0
                    }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "saveAsImagePdf failed", e)
                File(outPath + ".tmp").delete()
                made = 0
            } finally {
                pdf.close()
            }
            return made
        }
    }

    // [작동원리] 현재 열린 문서를 LibreOffice의 PDF 내보내기로 저장한다.
    // Word/PPT/ODS 등을 PDF 화면(이어서 스크롤)으로 보여 주기 위해 사용한다.
    fun saveAsPdf(outPath: String): Boolean {
        synchronized(syncLock) {
            val doc = document ?: return false
            return try {
                doc.saveAs(outPath, "pdf", "")
                val f = File(outPath)
                f.exists() && f.length() > 0
            } catch (e: Exception) {
                Log.e(TAG, "saveAsPdf failed", e)
                false
            }
        }
    }

    fun extractText(): String? {
        synchronized(syncLock) {
            val doc = document ?: return null
            try {
                val tempFile = File.createTempFile("lokit_text_", ".txt")
                tempFile.deleteOnExit()
                doc.saveAs(tempFile.absolutePath, "text", "")
                val text = tempFile.readText()
                tempFile.delete()
                return text
            } catch (e: Exception) {
                Log.e(TAG, "extractText failed", e)
                return null
            }
        }
    }

    fun extractPartText(part: Int): String? {
        synchronized(syncLock) {
            val doc = document ?: return null
            try {
                doc.setPart(part)
                val tempFile = File.createTempFile("lokit_text_", ".txt")
                tempFile.deleteOnExit()
                doc.saveAs(tempFile.absolutePath, "text", "")
                val text = tempFile.readText()
                tempFile.delete()
                return text
            } catch (e: Exception) {
                Log.e(TAG, "extractPartText failed for part $part", e)
                return null
            }
        }
    }

    fun closeDocument() {
        synchronized(syncLock) { closeDocumentInternal() }
    }

    private fun closeDocumentInternal() {
        document?.destroy()
        document = null
    }

    fun destroy() {
        synchronized(syncLock) {
            closeDocumentInternal()
            office?.destroy()
            office = null
        }
    }
}
