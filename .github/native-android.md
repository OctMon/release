# Release Native Android

在 GitHub Actions 的 **Run workflow** 中选择项目，填写该项目 `main` 上的完整提交 SHA。`upload_internal` 默认关闭，签名 AAB 保存在本次运行的 Artifacts。

## 接入新项目

1. 在 [工作流](workflows/release-native-android.yml) 的 `project.options` 加入项目代号，例如 `example`。代号以小写字母开头，可包含小写字母、数字和下划线。
2. 在发布仓库设置 `EXAMPLE_ANDROID_REPO`，填源码仓库的 SSH 克隆地址。共用的 `SSH_PRIVATE_KEY` 需要有该仓库的读取权限。工作流会使用 `native-android-example` 环境。
3. 在源码仓库添加 `.github/native-android.yml`，并在当前 Gradle 项目的 release 构建中配置上传签名。`bundle` 和 `mapping` 相对于 `project`，未启用代码混淆时可省略 `mapping`。

```yaml
schema_version: 1
project: .
package_name: com.example.android
module: ':app'
bundle: app/build/outputs/bundle/release/app-release.aab
mapping: app/build/outputs/mapping/release/mapping.txt
java_version: '21'
sdk_platform: android-37.0
build_tools: '36.0.0'
```

Gradle 的 `versionCode` 要读取 `exampleVersionCode`。已有项目使用其他 Gradle 属性名时，在源码配置中指定 `version_code_property`。CI 传入 GitHub Actions 的运行编号，并校验 AAB 的签名、包名和版本号。

需要项目专用检查时，可在源码仓库的 `scripts/` 中提供 `validate_catalog.py` 和 `validate_bundle.py`。产物检查脚本的第一个参数是 AAB 路径。

完成 Google Play 的首次手动上传后，如需启用内部测试上传，在该项目的 GitHub 环境中设置 `EXAMPLE_PLAY_SERVICE_ACCOUNT_JSON`。
