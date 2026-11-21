# 参与开发

环境、构建和架构见 [DEVELOPMENT.md](DEVELOPMENT.md)。

把示例模块 `native/module_example/jsexample` 放进数据目录的 `modules` 下，目录、分类、搜索和详情都能走通，播放会提示不可用。

提交 PR 时：

- 用户能感知的改动在 `CHANGELOG.md` 当前版本一节补一条。
- 界面改动不写单元测试，在 PR 里写清楚在哪个页面验证过。
- 不新增解释性代码注释，靠命名和模块边界表达意图。
- 不要提交 `android/app/src/main/jniLibs` 里的核心库。

本仓库不接受具体站点的代码，站源请做成独立的站源模块。
