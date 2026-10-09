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
package com.rtbishop.look4sat.core.domain

import com.rtbishop.look4sat.core.domain.utility.SatelliteCatalogParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SatelliteCatalogParserTest {

    @Test
    fun `common catalog parser creates a target that calculates positions and passes`() {
        val catalog = """
            OBJECT_NAME,EPOCH,MEAN_MOTION,ECCENTRICITY,INCLINATION,RA_OF_ASC_NODE,ARG_OF_PERICENTER,MEAN_ANOMALY,NORAD_CAT_ID,BSTAR,MEAN_MOTION_DOT
            "ISS, ZARYA",2024-03-09T05:45:04.737024,15.49756209,.0005741,51.6418,90.7424,343.9724,92.8274,25544,.00025016,.0001373
        """.trimIndent()

        val target = SatelliteCatalogParser().parseCatalog(catalog).single()
        assertEquals("ISS, ZARYA", target.name)
        assertEquals(25544, target.catalogNumber)

        val observer = doubleArrayOf(37.7749, -122.4194)
        val time = 1_710_000_000_000L
        val position = target.currentPosition(observer[0], observer[1], 0.0, time)
        assertTrue(position.elevationDegrees.isFinite())
        assertTrue(position.distanceKilometers > 0.0)

        val pass = target.nextPass(observer[0], observer[1], 0.0, time)
        assertNotNull(pass)
        val prediction = requireNotNull(pass)
        assertTrue(prediction.losTimeMillis > time)
        assertTrue(prediction.losTimeMillis > prediction.aosTimeMillis)
        assertTrue(prediction.maximumElevationDegrees > 0.0)
    }
}
