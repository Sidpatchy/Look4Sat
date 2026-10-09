/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Copyright (C) 2019-2026 Arty Bishop and contributors.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
package com.rtbishop.look4sat.core.domain.utility

import com.rtbishop.look4sat.core.domain.model.SatRadio
import com.rtbishop.look4sat.core.domain.predict.OrbitalData
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.decodeFromJsonElement
import java.io.InputStream

/** JVM stream adapter retained for the Android data layer. Parsing logic lives in common code. */
class DataParser(private val dispatcher: CoroutineDispatcher) {

    private val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
    }
    private val orbitalDataParser = OrbitalDataParser()

    fun isLeapYear(year: Int): Boolean = orbitalDataParser.isLeapYear(year)

    fun getDayOfYear(year: Int, month: Int, dayOfMonth: Int): Int =
        orbitalDataParser.getDayOfYear(year, month, dayOfMonth)

    suspend fun parseCSVStream(stream: InputStream): List<OrbitalData> = withContext(dispatcher) {
        stream.bufferedReader().use { orbitalDataParser.parseCatalog(it.readText()) }
    }

    suspend fun parseTLEStream(stream: InputStream): List<OrbitalData> = withContext(dispatcher) {
        stream.bufferedReader().use { orbitalDataParser.parseTLE(it.readText()) }
    }

    suspend fun parseJSONStream(stream: InputStream): List<SatRadio> = withContext(dispatcher) {
        stream.bufferedReader().use { reader ->
            runCatching {
                val root = json.parseToJsonElement(reader.readText())
                (root as? JsonArray)?.mapNotNull { element ->
                    runCatching { json.decodeFromJsonElement<SatRadio>(element) }
                        .onFailure { println("JSON parsing exception: $it") }
                        .getOrNull()
                } ?: emptyList()
            }.getOrDefault(emptyList())
        }
    }
}
