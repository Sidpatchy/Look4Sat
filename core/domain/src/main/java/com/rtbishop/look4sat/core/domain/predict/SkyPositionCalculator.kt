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

/** Swift-friendly bridge for map coordinates and daily solar events. */
class SkyPositionCalculator {

    fun mapPositions(timeMillis: Long): CelestialMapPositions {
        // A zeroed observer gives a stable geocentric sub-lunar point for the world map.
        val observer = GeoPos(0.0, 0.0)
        val sun = CelestialComputer.getSunPosition(observer, timeMillis)
        val moon = CelestialComputer.getMoonPosition(observer, timeMillis)
        return CelestialMapPositions(
            sunLatitudeDegrees = sun.latitude,
            sunLongitudeDegrees = sun.longitude,
            moonLatitudeDegrees = moon.declination,
            moonLongitudeDegrees = if (moon.gha <= 180.0) -moon.gha else 360.0 - moon.gha
        )
    }

    fun findSunRiseSet(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        startTimeMillis: Long
    ): CelestialRiseSetTimes {
        val times = CelestialComputer.findSunRiseSet(
            GeoPos(latitude, longitude, altitudeMeters),
            startTimeMillis
        )
        return CelestialRiseSetTimes(times.riseTimeMillis, times.setTimeMillis)
    }
}

data class CelestialMapPositions(
    val sunLatitudeDegrees: Double,
    val sunLongitudeDegrees: Double,
    val moonLatitudeDegrees: Double,
    val moonLongitudeDegrees: Double
)

data class CelestialRiseSetTimes(
    val sunriseTimeMillis: Long,
    val sunsetTimeMillis: Long
)
