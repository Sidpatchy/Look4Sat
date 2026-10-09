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

import com.rtbishop.look4sat.core.domain.predict.OrbitalData
import kotlin.math.pow

/** Platform-independent parsers for the orbital element formats used by Celestrak and SatNOGS. */
class OrbitalDataParser {

    private val alpha5Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    private val celestrakCSVColumns = mapOf(
        "OBJECT_NAME" to 0,
        "EPOCH" to 2,
        "MEAN_MOTION" to 3,
        "ECCENTRICITY" to 4,
        "INCLINATION" to 5,
        "RA_OF_ASC_NODE" to 6,
        "ARG_OF_PERICENTER" to 7,
        "MEAN_ANOMALY" to 8,
        "NORAD_CAT_ID" to 11,
        "BSTAR" to 14,
        "MEAN_MOTION_DOT" to 15
    )

    fun parseCatalog(csv: String): List<OrbitalData> {
        val lines = csv.lineSequence().iterator()
        if (!lines.hasNext()) return emptyList()
        val columns = parseCSVColumns(splitCSVLine(lines.next()))
        return lines.asSequence().mapNotNull { line ->
            runCatching { parseCSV(splitCSVLine(line), columns) }.getOrNull()
        }.toList()
    }

    fun parseTLE(tle: String): List<OrbitalData> = tle.lineSequence()
        .map(String::trimEnd)
        .filter(String::isNotBlank)
        .toList()
        .chunked(3)
        .filter { it.size == 3 && it[1].startsWith("1") && it[2].startsWith("2") }
        .mapNotNull { lines -> runCatching { parseTLELines(lines) }.getOrNull() }

    private fun parseCSV(values: List<String>, columns: Map<String, Int>): OrbitalData {
        fun value(column: String) = values[columns.getValue(column)].trim()
        fun optionalValue(column: String) = columns[column]?.let { values.getOrNull(it) }
            ?.trim()?.toDoubleOrNull() ?: 0.0

        return OrbitalData(
            name = value("OBJECT_NAME"),
            epoch = parseTimestamp(value("EPOCH")),
            meanmo = value("MEAN_MOTION").toDouble(),
            eccn = value("ECCENTRICITY").toDouble(),
            incl = value("INCLINATION").toDouble(),
            raan = value("RA_OF_ASC_NODE").toDouble(),
            argper = value("ARG_OF_PERICENTER").toDouble(),
            meanan = value("MEAN_ANOMALY").toDouble(),
            catnum = parseCatnum(value("NORAD_CAT_ID")),
            bstar = optionalValue("BSTAR"),
            ndot = optionalValue("MEAN_MOTION_DOT")
        )
    }

    /** Column order varies between OMM providers; retain Celestrak's fixed layout as a fallback. */
    private fun parseCSVColumns(header: List<String>): Map<String, Int> {
        val columns = header.withIndex().associate { (index, name) ->
            name.trim().trim('"').uppercase() to index
        }
        return if (columns.containsKey("NORAD_CAT_ID")) columns else celestrakCSVColumns
    }

    private fun splitCSVLine(line: String): List<String> {
        val fields = mutableListOf<String>()
        val field = StringBuilder()
        var quoted = false
        var index = 0
        while (index < line.length) {
            val char = line[index]
            when {
                char == '"' && quoted && line.getOrNull(index + 1) == '"' -> {
                    field.append('"')
                    index++
                }
                char == '"' -> quoted = !quoted
                char == ',' && !quoted -> {
                    fields += field.toString()
                    field.clear()
                }
                else -> field.append(char)
            }
            index++
        }
        fields += field.toString()
        return fields
    }

    private fun parseTimestamp(timestamp: String): Double {
        val year = timestamp.substring(0, 4).toInt()
        val month = timestamp.substring(5, 7).toInt()
        val day = timestamp.substring(8, 10).toInt()
        val hours = timestamp.substring(11, 13).toInt()
        val minutes = timestamp.substring(14, 16).toInt()
        val seconds = timestamp.substring(17).takeWhile { it.isDigit() || it == '.' }.toDouble()
        val fraction = (hours * 3600 + minutes * 60 + seconds) / 86400.0
        return (year % 100) * 1000 + getDayOfYear(year, month, day) + fraction
    }

    private fun parseCatnum(value: String): Int {
        val catalogNumber = value.trim()
        if (catalogNumber.first().isDigit()) return catalogNumber.toInt()
        val alphaIndex = alpha5Alphabet.indexOf(catalogNumber.first().uppercaseChar())
        require(alphaIndex >= 0) { "Unknown Alpha-5 catalog number: $catalogNumber" }
        return (alphaIndex + 10) * 10000 + catalogNumber.drop(1).trim().toInt()
    }

    private fun parseTLELines(lines: List<String>): OrbitalData {
        val line1 = lines[1]
        val line2 = lines[2]
        return OrbitalData(
            name = lines[0].trim().removePrefix("0 "),
            epoch = line1.substring(18, 32).toDouble(),
            meanmo = line2.substring(52, 63).toDouble(),
            eccn = line2.substring(26, 33).toDouble() / 1e7,
            incl = line2.substring(8, 16).toDouble(),
            raan = line2.substring(17, 25).toDouble(),
            argper = line2.substring(34, 42).toDouble(),
            meanan = line2.substring(43, 51).toDouble(),
            catnum = parseCatnum(line1.substring(2, 7)),
            bstar = 1e-5 * line1.substring(53, 59).toDouble() / 10.0.pow(line1.substring(60, 61).toDouble()),
            ndot = line1.substring(33, 43).trim().toDouble()
        )
    }

    fun getDayOfYear(year: Int, month: Int, day: Int): Int {
        val daysInMonth = intArrayOf(31, if (isLeapYear(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        return daysInMonth.take(month - 1).sum() + day
    }

    fun isLeapYear(year: Int) = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}
