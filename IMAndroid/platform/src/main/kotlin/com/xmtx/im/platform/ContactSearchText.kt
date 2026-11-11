package com.xmtx.im.platform

import android.icu.text.BreakIterator
import java.text.Normalizer
import java.util.Locale

/** Swift contact search: whole-string NFKC, locale-independent lowercase, grapheme substring. */
internal object ContactSearchText {
    fun tokens(input:String):String {
        val text=Normalizer.normalize(input,Normalizer.Form.NFKC).lowercase(Locale.ROOT)
        val iterator=BreakIterator.getCharacterInstance(Locale.ROOT).apply {setText(text)}
        val tokens=mutableListOf<String>();var start=iterator.first();var end=iterator.next()
        val digits="0123456789abcdef"
        while(end!=BreakIterator.DONE) {
            val token=StringBuilder("u1")
            for(byte in text.substring(start,end).toByteArray(Charsets.UTF_8)) {
                val value=byte.toInt() and 255;token.append(digits[value shr 4]);token.append(digits[value and 15])
            }
            tokens+=token.toString();start=end;end=iterator.next()
        }
        return tokens.joinToString(" ")
    }
}
