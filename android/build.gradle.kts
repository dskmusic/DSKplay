allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (e.g. audiotags) hardcode an old compileSdkVersion in their
// own build.gradle instead of inheriting it from the app, which then fails
// AAR metadata checks against newer androidx transitive dependencies. Force
// every Android library module to compile against the same SDK as the app.
// This must run in `afterEvaluate` so it applies *after* the plugin's own
// build.gradle has already set its (outdated) compileSdkVersion, otherwise
// that later assignment would just overwrite ours back down.
// `:app` is skipped: `evaluationDependsOn(":app")` above already forces it
// to fully evaluate very early, so calling `afterEvaluate` on it here would
// throw ("project already evaluated") - and :app doesn't need this fix
// anyway since it sets its own compileSdk directly.
subprojects {
    if (name == "app") return@subprojects
    afterEvaluate {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.compileSdk = 36
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
