import 'package:flutter/material.dart';

import 'generated/tokens.g.dart';

enum EfelantThemeId { primary, secondary }

class EfelantThemeColors {
  const EfelantThemeColors({
    required this.bg,
    required this.bgRaised,
    required this.bgOverlay,
    required this.text,
    required this.textMuted,
    required this.border,
    required this.accent,
    required this.accentSoft,
    required this.accentContrast,
    required this.mine,
    required this.theirs,
    required this.danger,
    required this.ok,
  });

  final Color bg;
  final Color bgRaised;
  final Color bgOverlay;
  final Color text;
  final Color textMuted;
  final Color border;
  final Color accent;
  final Color accentSoft;
  final Color accentContrast;
  final Color mine;
  final Color theirs;
  final Color danger;
  final Color ok;

  factory EfelantThemeColors.of(EfelantThemeId id) {
    switch (id) {
      case EfelantThemeId.primary:
        return const EfelantThemeColors(
          bg: EfelantTokens.colorBg,
          bgRaised: EfelantTokens.colorBgRaised,
          bgOverlay: EfelantTokens.colorBgOverlay,
          text: EfelantTokens.colorText,
          textMuted: EfelantTokens.colorTextMuted,
          border: EfelantTokens.colorBorder,
          accent: EfelantTokens.colorAccent,
          accentSoft: EfelantTokens.colorAccentSoft,
          accentContrast: EfelantTokens.colorAccentContrast,
          mine: EfelantTokens.colorMine,
          theirs: EfelantTokens.colorTheirs,
          danger: EfelantTokens.colorDanger,
          ok: EfelantTokens.colorOk,
        );
      case EfelantThemeId.secondary:
        return const EfelantThemeColors(
          bg: EfelantTokensSecondary.colorBg,
          bgRaised: EfelantTokensSecondary.colorBgRaised,
          bgOverlay: EfelantTokensSecondary.colorBgOverlay,
          text: EfelantTokensSecondary.colorText,
          textMuted: EfelantTokensSecondary.colorTextMuted,
          border: EfelantTokensSecondary.colorBorder,
          accent: EfelantTokensSecondary.colorAccent,
          accentSoft: EfelantTokensSecondary.colorAccentSoft,
          accentContrast: EfelantTokensSecondary.colorAccentContrast,
          mine: EfelantTokensSecondary.colorMine,
          theirs: EfelantTokensSecondary.colorTheirs,
          danger: EfelantTokensSecondary.colorDanger,
          ok: EfelantTokensSecondary.colorOk,
        );
    }
  }
}

ThemeData buildEfelantTheme({
  EfelantThemeId theme = EfelantThemeId.primary,
  String? fontFamily,
  List<String>? fontFamilyFallback,
}) {
  final colors = EfelantThemeColors.of(theme);
  final brightness = switch (theme) {
    EfelantThemeId.primary => Brightness.dark,
    EfelantThemeId.secondary => Brightness.light,
  };
  final base = ColorScheme.fromSeed(
    seedColor: colors.accent,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    colorScheme: base.copyWith(
      primary: colors.accent,
      onPrimary: colors.accentContrast,
      surface: colors.bg,
      onSurface: colors.text,
      surfaceContainerHighest: colors.bgOverlay,
      error: colors.danger,
    ),
    scaffoldBackgroundColor: colors.bg,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.bg,
      foregroundColor: colors.text,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: colors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(EfelantTokens.radiusMd),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.bgRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(EfelantTokens.radiusMd),
        borderSide: BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: colors.accentContrast,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EfelantTokens.radiusMd),
        ),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
