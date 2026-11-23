buildscript {
    val t28Distribution =
        project.findProperty("t28Distribution")?.toString() ?: "platform"
    repositories {
        google()
        mavenCentral()
        if (t28Distribution == "huaweiRestricted") {
            // AG Connect's Gradle plugin is resolved only for the licensed
            // Huawei release channel; the default build does not load it.
            maven("https://developer.huawei.com/repo/")
        }
    }
    dependencies {
        if (t28Distribution == "huaweiRestricted") {
            classpath("com.huawei.agconnect:agcp:1.9.3.300")
        }
    }
}

val t28Distribution =
    providers.gradleProperty("t28Distribution").orElse("platform").get()

allprojects {
    repositories {
        google()
        mavenCentral()
        if (t28Distribution == "huaweiRestricted") {
            maven("https://developer.huawei.com/repo/")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
