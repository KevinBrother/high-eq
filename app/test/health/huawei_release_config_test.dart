import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restricted Huawei release requires an explicit app id', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(
      gradle,
      matches(RegExp(r'providers\.gradleProperty\("t28HuaweiAppId"\)')),
    );
    expect(
      gradle,
      matches(
        RegExp(
          r'if \(huaweiRestricted\)[\s\S]*require\(huaweiAppId\.isNotEmpty\(\)\)',
        ),
      ),
    );
    expect(gradle, contains('huaweiAppId.matches(Regex("[0-9]+"))'));
  });

  test('ordinary platform channel does not receive restricted app id', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(
      gradle,
      matches(
        RegExp(
          r'val huaweiAppId =\s*if \(huaweiRestricted\) providers\.gradleProperty\("t28HuaweiAppId"\)\.orElse\(""\)\.get\(\)\.trim\(\) else ""',
        ),
      ),
    );
  });

  test('release app id is wired to AG Connect metadata', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      gradle,
      contains(
        'android.defaultConfig.manifestPlaceholders["t28HuaweiAppId"] = huaweiAppId',
      ),
    );
    expect(
      gradle,
      contains(
        'android.defaultConfig.resValue("string", "t28_huawei_app_id", huaweiAppId)',
      ),
    );
    expect(manifest, contains('android:name="com.huawei.hms.client.appid"'));
    expect(manifest, contains(r'android:value="${t28HuaweiAppId}"'));
  });

  test('native preflight reads the same injected release app id', () {
    final activity = File(
      'android/app/src/main/kotlin/cn/higheq/high_eq/MainActivity.kt',
    ).readAsStringSync();

    expect(activity, contains('"huaweiAppId"'));
    expect(activity, contains('R.string.t28_huawei_app_id'));
    expect(activity, isNot(contains('BuildConfig.T28_HUAWEI_APP_ID')));
  });

  test('AG Connect plugin is applied only for a restricted release', () {
    final rootGradle = File('android/build.gradle.kts').readAsStringSync();
    final appGradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(
      rootGradle,
      matches(
        RegExp(
          r'if \(t28Distribution == "huaweiRestricted"\)[\s\S]*classpath\("com\.huawei\.agconnect:agcp:1\.9\.3\.300"\)',
        ),
      ),
    );
    expect(
      appGradle,
      matches(
        RegExp(
          r'if \(huaweiRestricted\) \{[\s\S]*require\(file\("agconnect-services\.json"\)\.isFile\)[\s\S]*apply\(plugin = "com\.huawei\.agconnect"\)',
        ),
      ),
    );
    expect(appGradle, isNot(contains('id("com.huawei.agconnect")')));
  });

  test('AG Connect project file stays outside source control', () {
    final gitignore = File('android/.gitignore').readAsStringSync();

    expect(gitignore, contains('agconnect-services.json'));
  });
}
