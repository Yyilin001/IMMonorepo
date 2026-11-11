package com.xmtx.im.platform

import android.icu.text.BreakIterator
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import java.text.Normalizer
import java.util.Locale

/** Mirrors MessageSubstringSearch's compatibilityCaseInsensitive grapheme phrase encoding.
 * ASCII hex tokens prevent FTS operators, punctuation and user text from becoming query syntax. */
internal class MessageSearchText(text: String) {
    private data class Token(val value: String, val start: Int, val end: Int)
    private val pattern = tokenize(text)
    val phrase = pattern.joinToString(" ") { it.value }
    val empty get() = pattern.isEmpty()
    private val failure = IntArray(pattern.size).also { table ->
        var matched = 0
        for (index in 1 until pattern.size) {
            while (matched > 0 && pattern[index].value != pattern[matched].value) matched = table[matched-1]
            if (pattern[index].value == pattern[matched].value) matched++
            table[index] = matched
        }
    }
    fun preview(text: String): MessageSearchPreview? {
        val tokens = tokenize(text)
        val matches = mutableListOf<MessageSearchRange>()
        if (!empty) {
            var matched = 0
            for ((i,token) in tokens.withIndex()) {
                while (matched > 0 && token.value != pattern[matched].value) matched = failure[matched-1]
                if (token.value == pattern[matched].value) matched++
                if (matched == pattern.size) {
                    val start = tokens[i-pattern.size+1].start
                    val range = MessageSearchRange(start, token.end-start)
                    if (matches.lastOrNull() != range) matches += range
                    matched = failure[matched-1]
                    if (matches.size == 100) break
                }
            }
            if (matches.isEmpty()) return null
        }
        val start = matches.firstOrNull()?.offset ?: 0
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT).apply { setText(text) }
        var end = start
        repeat(120) { if (end < text.length) end = iterator.following(end).takeIf { it != BreakIterator.DONE } ?: text.length }
        // Do not cut the first match, even when the user's query itself exceeds the preview width.
        end = maxOf(end, matches.firstOrNull()?.let {it.offset+it.length} ?: 0)
        val prefix = if (start > 0) "…" else ""
        val excerpt = prefix + text.substring(start,end) + if(end < text.length) "…" else ""
        return MessageSearchPreview(excerpt, matches.filter {it.offset < end && it.offset+it.length > start}.map {
            MessageSearchRange(it.offset-start+prefix.length, minOf(it.length,end-it.offset))
        }.toPersistentList())
    }
    companion object {
        fun encode(text: String) = tokenize(text).joinToString(" ") {it.value}
        private fun tokenize(text: String): List<Token> {
            data class Boundary(val normalized: Int, val original: Int)
            val boundaries = mutableListOf(Boundary(0,0));val normalized = StringBuilder()
            val iterator = BreakIterator.getCharacterInstance(Locale.ROOT).apply {setText(text)}
            var start = iterator.first();var end = iterator.next()
            while(end != BreakIterator.DONE) {
                normalized.append(Normalizer.normalize(text.substring(start,end),Normalizer.Form.NFKC).lowercase(Locale.ROOT))
                boundaries += Boundary(normalized.length,end);start=end;end=iterator.next()
            }
            val value=normalized.toString();iterator.setText(value)
            start=iterator.first();end=iterator.next();var source=0
            return buildList {
                while(end != BreakIterator.DONE) {
                    while(boundaries[source+1].normalized <= start) source++
                    val first=boundaries[source].original
                    while(boundaries[source+1].normalized < end) source++
                    val last=boundaries[source+1].original
                    val bytes=Normalizer.normalize(value.substring(start,end),Normalizer.Form.NFC).toByteArray(Charsets.UTF_8)
                    val hex=StringBuilder("x");val digits="0123456789abcdef"
                    for(byte in bytes) {val n=byte.toInt() and 255;hex.append(digits[n shr 4]);hex.append(digits[n and 15])}
                    add(Token(hex.toString(),first,last));start=end;end=iterator.next()
                }
            }
        }
    }
}
