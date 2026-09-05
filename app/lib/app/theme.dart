import 'package:efelant_flutter/efelant.dart' as sdk;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

export 'package:efelant_flutter/efelant.dart'
    show EfelantThemeColors, EfelantThemeId, EfelantTokens, EfelantTokensSecondary;

abstract final class EfelantColors {
  static const navy = sdk.EfelantTokens.colorBg;
  static const navyMid = sdk.EfelantTokens.colorBgRaised;
  static const navyLight = sdk.EfelantTokens.colorBgOverlay;
  static const accent = sdk.EfelantTokens.colorAccent;
  static const accentSoft = sdk.EfelantTokens.colorAccentSoft;
  static const bubbleMine = sdk.EfelantTokens.colorMine;
  static const bubbleTheirs = sdk.EfelantTokens.colorTheirs;
}

const kEfelantEmojiFallback = <String>['EfelantEmoji'];

Future<void> loadEfelantFonts() async {
  final sans = FontLoader('EfelantSans')
    ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Roboto-Medium.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
  final emoji = FontLoader('EfelantEmoji')
    ..addFont(rootBundle.load('assets/fonts/NotoEmoji.ttf'));
  await Future.wait([sans.load(), emoji.load()]);
}

TextTheme _withEmojiFallback(TextTheme theme) {
  TextStyle? add(TextStyle? style) {
    if (style == null) {
      return null;
    }
    return style.copyWith(fontFamilyFallback: kEfelantEmojiFallback);
  }

  return theme.copyWith(
    displayLarge: add(theme.displayLarge),
    displayMedium: add(theme.displayMedium),
    displaySmall: add(theme.displaySmall),
    headlineLarge: add(theme.headlineLarge),
    headlineMedium: add(theme.headlineMedium),
    headlineSmall: add(theme.headlineSmall),
    titleLarge: add(theme.titleLarge),
    titleMedium: add(theme.titleMedium),
    titleSmall: add(theme.titleSmall),
    bodyLarge: add(theme.bodyLarge),
    bodyMedium: add(theme.bodyMedium),
    bodySmall: add(theme.bodySmall),
    labelLarge: add(theme.labelLarge),
    labelMedium: add(theme.labelMedium),
    labelSmall: add(theme.labelSmall),
  );
}

ThemeData buildEfelantTheme({
  sdk.EfelantThemeId theme = sdk.EfelantThemeId.primary,
}) {
  final base = sdk.buildEfelantTheme(
    theme: theme,
    fontFamily: 'EfelantSans',
    fontFamilyFallback: kEfelantEmojiFallback,
  );
  return base.copyWith(
    textTheme: _withEmojiFallback(base.textTheme),
    primaryTextTheme: _withEmojiFallback(base.primaryTextTheme),
  );
}
