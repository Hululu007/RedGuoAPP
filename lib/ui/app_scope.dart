import 'package:flutter/widgets.dart';

import '../core_bridge.dart';

enum FormFactor { phone, pad, window, television }

const televisionInset = 58.0;

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repository,
    this.formFactor,
    this.isTelevisionDevice = false,
    this.systemColorAvailable = false,
    this.version = '',
    required super.child,
  });
  final AppRepository repository;
  final FormFactor? formFactor;

  /// 设备本身是否被识别为电视（与手动选择的界面模式无关）。
  ///
  /// 真电视设备隐藏「界面模式」设置——切到手机/平板界面后遥控器没法操作；
  /// 手机等设备即便手动切到电视界面，也要保留这个入口，否则切回不去。
  final bool isTelevisionDevice;
  final bool systemColorAvailable;
  final String version;

  bool get television => formFactor == FormFactor.television;

  /// 当前是否处于真电视的电视界面：唯一允许隐藏「界面模式」的场景。
  bool get canHideDisplayModeSwitch => isTelevisionDevice && television;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  static FormFactor formFactorOf(BuildContext context) {
    if (of(context).formFactor case final form?) return form;
    final size = MediaQuery.sizeOf(context);
    return size.shortestSide >= 600 ? FormFactor.pad : FormFactor.phone;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repository != oldWidget.repository ||
      formFactor != oldWidget.formFactor ||
      isTelevisionDevice != oldWidget.isTelevisionDevice ||
      systemColorAvailable != oldWidget.systemColorAvailable ||
      version != oldWidget.version;
}
