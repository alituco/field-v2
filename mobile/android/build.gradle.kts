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

    if (name == "stripe_android") {
        // PaymentSheet does not issue cards. Stripe's optional compile-only
        // provisioning API pulls this restricted Google artifact into lint;
        // exclude only that artifact, keeping normal payments and release lint.
        configurations.configureEach {
            exclude(
                group = "com.google.android.gms",
                module = "play-services-tapandpay",
            )
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
