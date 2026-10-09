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
package com.rtbishop.look4sat.convention

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.jetbrains.kotlin.gradle.dsl.KotlinMultiplatformExtension

@Suppress("Unused")
internal class CoreDomainPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        applyPlugin(libs.plugins.kotlin.multiplatform)
        applyPlugin(libs.plugins.kotlin.serialization)
        extensions.configure<KotlinMultiplatformExtension> {
            jvmToolchain(libs.versions.jdkVersion.get().toInt())
            jvm()
            iosArm64().binaries.framework {
                baseName = "Look4SatShared"
                isStatic = true
                export(libs.kotlin.coroutines)
            }
            iosSimulatorArm64().binaries.framework {
                baseName = "Look4SatShared"
                isStatic = true
                export(libs.kotlin.coroutines)
            }
            iosX64().binaries.framework {
                baseName = "Look4SatShared"
                isStatic = true
                export(libs.kotlin.coroutines)
            }
            val commonMain = sourceSets.getByName("commonMain")
            commonMain.kotlin.srcDir("src/main/java")
            commonMain.dependencies {
                api(libs.kotlin.coroutines)
            }
            val jvmMain = sourceSets.getByName("jvmMain")
            jvmMain.dependencies {
                implementation(libs.kotlin.serialization)
            }
            val jvmTest = sourceSets.getByName("jvmTest")
            jvmTest.kotlin.srcDir("src/test/java")
            jvmTest.dependencies {
                implementation(libs.bundles.unitTest)
            }
        }
    }
}
