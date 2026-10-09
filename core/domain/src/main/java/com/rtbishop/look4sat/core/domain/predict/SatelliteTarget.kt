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
package com.rtbishop.look4sat.core.domain.predict

import kotlin.math.PI

/** Small Swift-friendly wrapper around the shared SGP4/SDP4 implementation. */
class SatelliteTarget internal constructor(private val data: OrbitalData) {

    val name: String get() = data.name
    val catalogNumber: Int get() = data.catnum
    val isDeepSpace: Boolean get() = data.isDeepSpace
    val orbitalPeriodMinutes: Double get() = data.orbitalPeriod
    val elementEpochDaynum: Double get() = data.epochDaynum

    fun currentPosition(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        timeMillis: Long
    ): SatellitePosition {
        val position = data.getObject().getFullPosition(GeoPos(latitude, longitude, altitudeMeters), timeMillis)
        return SatellitePosition(
            azimuthDegrees = position.azimuth * 180.0 / PI,
            elevationDegrees = position.elevation * 180.0 / PI,
            latitudeDegrees = position.latitude * 180.0 / PI,
            longitudeDegrees = if (position.longitude * 180.0 / PI > 180.0) {
                position.longitude * 180.0 / PI - 360.0
            } else {
                position.longitude * 180.0 / PI
            },
            altitudeKilometers = position.altitude,
            distanceKilometers = position.distance,
            distanceRateKilometersPerSecond = position.distanceRate,
            isAboveHorizon = position.aboveHorizon
        )
    }

    /** Predict the next pass using the same SGP4/SDP4 elevation calculations as the Android app. */
    fun nextPass(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        startTimeMillis: Long
    ): SatellitePass? {
        val observer = GeoPos(latitude, longitude, altitudeMeters)
        val satellite = data.getObject()
        if (!satellite.willBeSeen(observer)) return null

        if (data.isDeepSpace) {
            val position = satellite.getFullPosition(observer, startTimeMillis)
            return SatellitePass(
                aosTimeMillis = startTimeMillis,
                aosAzimuthDegrees = position.azimuth * 180.0 / PI,
                losTimeMillis = startTimeMillis + DAY_MILLIS,
                losAzimuthDegrees = position.azimuth * 180.0 / PI,
                maximumElevationDegrees = position.elevation * 180.0 / PI,
                altitudeKilometers = position.altitude
            )
        }

        var cursor = startTimeMillis
        var elevation = satellite.getElevation(observer, cursor)
        var steps = 0

        // Rewind to the start of an in-progress pass so it remains visible in the pass list.
        while (elevation > 0.0 && steps++ < MAX_REWIND_STEPS) {
            cursor -= COARSE_SET_STEP_MILLIS
            elevation = satellite.getElevation(observer, cursor)
        }
        if (steps >= MAX_REWIND_STEPS) return null

        val searchEnd = startTimeMillis + MAX_SEARCH_MILLIS
        while (elevation <= 0.0 && cursor < searchEnd) {
            cursor += COARSE_RISE_STEP_MILLIS
            elevation = satellite.getElevation(observer, cursor)
        }
        if (elevation <= 0.0) return null

        var aos = cursor - COARSE_RISE_STEP_MILLIS
        var refineSteps = 0
        do {
            aos += REFINE_STEP_MILLIS
            elevation = satellite.getElevation(observer, aos)
        } while (elevation <= 0.0 && aos < cursor && refineSteps++ < MAX_REFINE_STEPS)
        val aosPosition = satellite.getFullPosition(observer, aos)

        var peakTime = aos
        var peakElevation = elevation
        cursor = aos
        steps = 0
        while (steps++ < MAX_PASS_STEPS) {
            cursor += COARSE_SET_STEP_MILLIS
            elevation = satellite.getElevation(observer, cursor)
            if (elevation > peakElevation) {
                peakElevation = elevation
                peakTime = cursor
            }
            if (elevation <= 0.0) break
        }
        if (elevation > 0.0) return null

        var los = cursor - COARSE_SET_STEP_MILLIS
        refineSteps = 0
        do {
            los += REFINE_STEP_MILLIS
            elevation = satellite.getElevation(observer, los)
        } while (elevation > 0.0 && los < cursor && refineSteps++ < MAX_REFINE_STEPS)
        val losPosition = satellite.getFullPosition(observer, los)
        val peakPosition = satellite.getFullPosition(observer, peakTime)

        return SatellitePass(
            aosTimeMillis = aosPosition.time,
            aosAzimuthDegrees = aosPosition.azimuth * 180.0 / PI,
            losTimeMillis = losPosition.time,
            losAzimuthDegrees = losPosition.azimuth * 180.0 / PI,
            maximumElevationDegrees = peakElevation * 180.0 / PI,
            altitudeKilometers = peakPosition.altitude
        )
    }

    private companion object {
        const val DAY_MILLIS = 24L * 60 * 60 * 1000
        const val MAX_SEARCH_MILLIS = 7L * DAY_MILLIS
        const val COARSE_RISE_STEP_MILLIS = 60L * 1000
        const val COARSE_SET_STEP_MILLIS = 30L * 1000
        const val REFINE_STEP_MILLIS = 500L
        const val MAX_REWIND_STEPS = 360
        const val MAX_PASS_STEPS = 360
        const val MAX_REFINE_STEPS = 240
    }
}

data class SatellitePosition(
    val azimuthDegrees: Double,
    val elevationDegrees: Double,
    val latitudeDegrees: Double,
    val longitudeDegrees: Double,
    val altitudeKilometers: Double,
    val distanceKilometers: Double,
    val distanceRateKilometersPerSecond: Double,
    val isAboveHorizon: Boolean
) {
    fun downlinkFrequency(frequencyHz: Long): Long =
        (frequencyHz.toDouble() * (SPEED_OF_LIGHT - distanceRateKilometersPerSecond * 1000.0) / SPEED_OF_LIGHT).toLong()

    fun uplinkFrequency(frequencyHz: Long): Long =
        (frequencyHz.toDouble() * (SPEED_OF_LIGHT + distanceRateKilometersPerSecond * 1000.0) / SPEED_OF_LIGHT).toLong()
}

data class SatellitePass(
    val aosTimeMillis: Long,
    val aosAzimuthDegrees: Double,
    val losTimeMillis: Long,
    val losAzimuthDegrees: Double,
    val maximumElevationDegrees: Double,
    val altitudeKilometers: Double
)
