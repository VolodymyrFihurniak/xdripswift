import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    kotlin("multiplatform") version "2.4.10"
}

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(17)
    jvm()

    val xcframework = XCFramework("Sibionics2Core")
    val iosTargets = listOf(iosArm64(), iosSimulatorArm64())
    iosTargets.forEach { target ->
        target.binaries.framework {
            baseName = "Sibionics2Core"
            isStatic = true
            xcframework.add(this)
        }
    }

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
        jvmTest.dependencies {
            implementation(kotlin("test-junit"))
        }
        jvmTest.resources.srcDir(rootProject.file("../xDrip Tests/Fixtures"))
    }
}
