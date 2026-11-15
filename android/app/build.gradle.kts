import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名信息放在仓库外（android/key.properties，已 gitignore）。
// 没有这个文件时回退到 debug 签名，方便别人 clone 下来直接跑。
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties().apply {
    if (keyPropsFile.exists()) FileInputStream(keyPropsFile).use { load(it) }
}
val hasReleaseKey = keyProps.getProperty("storeFile")?.isNotBlank() == true

android {
    namespace = "com.example.plc_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.plc_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 授权校验库：盐与校验算法在 native 层，签名基准在编译期注入
        externalNativeBuild {
            cmake {
                arguments += "-DEXPECTED_SIG=EC15458926D320DBED12DF91E8BDCBA7C2166C256F2CA46B78025E3A55557C0E"
            }
        }
        ndk {
            // 覆盖真机（arm64/armv7）与模拟器（x86_64）
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    lint {
        // AGP 9.3.1 的 lintVital 在本工具链上崩溃（JavaDocParser NoSuchMethodError），
        // 发布检查不影响 APK 产物，直接关闭。
        checkReleaseBuilds = false
        abortOnError = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
