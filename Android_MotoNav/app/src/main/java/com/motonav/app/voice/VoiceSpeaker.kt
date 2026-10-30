package com.motonav.app.voice

import android.content.Context
import android.speech.tts.TextToSpeech
import java.util.Locale

/** 语音播报封装（TTS） */
class VoiceSpeaker(context: Context) : TextToSpeech.OnInitListener {

    private val tts = TextToSpeech(context.applicationContext, this)
    private var ready = false

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            tts.language = Locale.CHINESE
        }
    }

    /** 播报文本；若未就绪则静默丢弃（提示层仍会用 Toast 兜底） */
    fun speak(text: String) {
        if (!ready) return
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "alert_${System.currentTimeMillis()}")
    }

    fun shutdown() {
        tts.stop()
        tts.shutdown()
    }
}
