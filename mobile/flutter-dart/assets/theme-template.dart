// ============================================================================
// Material 3 Theme Configuration Template
//
// Provides complete light and dark theme setup with:
// - Color scheme from seed color
// - Custom component themes
// - Typography configuration
// - Consistent spacing and shape system
//
// Copy to lib/core/theme/ and adapt to your brand.
// ============================================================================

import 'package:flutter/material.dart';

// ─── Color Seeds ────────────────────────────────────────────────────────────

abstract class AppColors {
  // Primary brand color — change this to match your brand
  static const Color seedColor = Color(0xFF4F46E5); // Indigo

  // Fixed semantic colors (not affected by theme)
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFD97706);
  static const Color info = Color(0xFF2563EB);

  // Generate color schemes from seed
  static final ColorScheme lightScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.light,
  );

  static final ColorScheme darkScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.dark,
  );
}

// ─── Spacing System ─────────────────────────────────────────────────────────

abstract class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  // Padding presets
  static const EdgeInsets pagePadding = EdgeInsets.all(md);
  static const EdgeInsets cardPadding = EdgeInsets.all(md);
  static const EdgeInsets listItemPadding =
      EdgeInsets.symmetric(horizontal: md, vertical: sm);
}

// ─── Shape System ───────────────────────────────────────────────────────────

abstract class AppShapes {
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;
  static const double radiusFull = 999;

  static final RoundedRectangleBorder cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radiusMd),
  );

  static final RoundedRectangleBorder dialogShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radiusXl),
  );

  static final RoundedRectangleBorder buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radiusSm),
  );
}

// ─── Typography ─────────────────────────────────────────────────────────────

abstract class AppTypography {
  // Use GoogleFonts for custom fonts:
  // static TextTheme textTheme = GoogleFonts.interTextTheme();
  // static TextTheme textTheme = GoogleFonts.notoSansTextTheme();

  // Or use the default Material 3 typography
  static TextTheme textTheme = const TextTheme(
    displayLarge: TextStyle(
      fontSize: 57,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.25,
      height: 1.12,
    ),
    displayMedium: TextStyle(
      fontSize: 45,
      fontWeight: FontWeight.w400,
      height: 1.16,
    ),
    displaySmall: TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w400,
      height: 1.22,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w600,
      height: 1.25,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      height: 1.29,
    ),
    headlineSmall: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      height: 1.33,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      height: 1.27,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.15,
      height: 1.50,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
      height: 1.43,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.5,
      height: 1.50,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.25,
      height: 1.43,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.4,
      height: 1.33,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
      height: 1.43,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
      height: 1.33,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
      height: 1.45,
    ),
  );
}

// ─── Theme Configuration ────────────────────────────────────────────────────

abstract class AppTheme {
  // ── Light Theme ──────────────────────────────────────────────────────────
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: AppColors.lightScheme,
        textTheme: AppTypography.textTheme,

        // Scaffold
        scaffoldBackgroundColor: AppColors.lightScheme.surface,

        // AppBar
        appBarTheme: AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 1,
          backgroundColor: AppColors.lightScheme.surface,
          foregroundColor: AppColors.lightScheme.onSurface,
          titleTextStyle: AppTypography.textTheme.titleLarge?.copyWith(
            color: AppColors.lightScheme.onSurface,
          ),
        ),

        // Cards
        cardTheme: CardTheme(
          elevation: 0,
          shape: AppShapes.cardShape,
          color: AppColors.lightScheme.surfaceContainerLowest,
          clipBehavior: Clip.antiAlias,
        ),

        // Elevated Buttons
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            shape: AppShapes.buttonShape,
            foregroundColor: AppColors.lightScheme.onPrimary,
            backgroundColor: AppColors.lightScheme.primary,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Filled Buttons
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            shape: AppShapes.buttonShape,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Outlined Buttons
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            shape: AppShapes.buttonShape,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Text Buttons
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            shape: AppShapes.buttonShape,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Input Decoration (TextFields)
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor:
              AppColors.lightScheme.surfaceContainerHighest.withOpacity(0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide(
              color: AppColors.lightScheme.outline.withOpacity(0.3),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide(
              color: AppColors.lightScheme.primary,
              width: 2,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide(
              color: AppColors.lightScheme.error,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          labelStyle: AppTypography.textTheme.bodyMedium,
          hintStyle: AppTypography.textTheme.bodyMedium?.copyWith(
            color: AppColors.lightScheme.onSurfaceVariant,
          ),
        ),

        // Floating Action Button
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          elevation: 2,
          highlightElevation: 4,
          backgroundColor: AppColors.lightScheme.primaryContainer,
          foregroundColor: AppColors.lightScheme.onPrimaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusMd),
          ),
        ),

        // Bottom Navigation Bar
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          backgroundColor: AppColors.lightScheme.surface,
          selectedItemColor: AppColors.lightScheme.primary,
          unselectedItemColor: AppColors.lightScheme.onSurfaceVariant,
          selectedLabelStyle: AppTypography.textTheme.labelSmall,
          unselectedLabelStyle: AppTypography.textTheme.labelSmall,
        ),

        // Navigation Bar (Material 3)
        navigationBarTheme: NavigationBarThemeData(
          elevation: 0,
          backgroundColor: AppColors.lightScheme.surface,
          indicatorColor: AppColors.lightScheme.secondaryContainer,
          labelTextStyle: WidgetStatePropertyAll(
            AppTypography.textTheme.labelSmall,
          ),
        ),

        // Dialogs
        dialogTheme: DialogTheme(
          elevation: 3,
          shape: AppShapes.dialogShape,
          backgroundColor: AppColors.lightScheme.surface,
          titleTextStyle: AppTypography.textTheme.headlineSmall?.copyWith(
            color: AppColors.lightScheme.onSurface,
          ),
          contentTextStyle: AppTypography.textTheme.bodyMedium?.copyWith(
            color: AppColors.lightScheme.onSurfaceVariant,
          ),
        ),

        // Snackbar
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
          ),
          backgroundColor: AppColors.lightScheme.inverseSurface,
          contentTextStyle: AppTypography.textTheme.bodyMedium?.copyWith(
            color: AppColors.lightScheme.onInverseSurface,
          ),
        ),

        // Chips
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
          ),
          labelStyle: AppTypography.textTheme.labelMedium,
        ),

        // Divider
        dividerTheme: DividerThemeData(
          color: AppColors.lightScheme.outlineVariant,
          thickness: 1,
          space: 1,
        ),

        // ListTile
        listTileTheme: ListTileThemeData(
          contentPadding: AppSpacing.listItemPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
          ),
        ),

        // Page transitions
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      );

  // ── Dark Theme ───────────────────────────────────────────────────────────
  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: AppColors.darkScheme,
        textTheme: AppTypography.textTheme,

        // Scaffold
        scaffoldBackgroundColor: AppColors.darkScheme.surface,

        // AppBar
        appBarTheme: AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 1,
          backgroundColor: AppColors.darkScheme.surface,
          foregroundColor: AppColors.darkScheme.onSurface,
          titleTextStyle: AppTypography.textTheme.titleLarge?.copyWith(
            color: AppColors.darkScheme.onSurface,
          ),
        ),

        // Cards
        cardTheme: CardTheme(
          elevation: 0,
          shape: AppShapes.cardShape,
          color: AppColors.darkScheme.surfaceContainerHighest,
          clipBehavior: Clip.antiAlias,
        ),

        // Elevated Buttons
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            shape: AppShapes.buttonShape,
            foregroundColor: AppColors.darkScheme.onPrimary,
            backgroundColor: AppColors.darkScheme.primary,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Filled Buttons
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            shape: AppShapes.buttonShape,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Outlined Buttons
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            shape: AppShapes.buttonShape,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Text Buttons
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            shape: AppShapes.buttonShape,
            textStyle: AppTypography.textTheme.labelLarge,
          ),
        ),

        // Input Decoration (TextFields)
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor:
              AppColors.darkScheme.surfaceContainerHighest.withOpacity(0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide(
              color: AppColors.darkScheme.outline.withOpacity(0.3),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide(
              color: AppColors.darkScheme.primary,
              width: 2,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
            borderSide: BorderSide(
              color: AppColors.darkScheme.error,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          labelStyle: AppTypography.textTheme.bodyMedium,
          hintStyle: AppTypography.textTheme.bodyMedium?.copyWith(
            color: AppColors.darkScheme.onSurfaceVariant,
          ),
        ),

        // Floating Action Button
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          elevation: 2,
          highlightElevation: 4,
          backgroundColor: AppColors.darkScheme.primaryContainer,
          foregroundColor: AppColors.darkScheme.onPrimaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusMd),
          ),
        ),

        // Bottom Navigation Bar
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          backgroundColor: AppColors.darkScheme.surface,
          selectedItemColor: AppColors.darkScheme.primary,
          unselectedItemColor: AppColors.darkScheme.onSurfaceVariant,
          selectedLabelStyle: AppTypography.textTheme.labelSmall,
          unselectedLabelStyle: AppTypography.textTheme.labelSmall,
        ),

        // Navigation Bar (Material 3)
        navigationBarTheme: NavigationBarThemeData(
          elevation: 0,
          backgroundColor: AppColors.darkScheme.surface,
          indicatorColor: AppColors.darkScheme.secondaryContainer,
          labelTextStyle: WidgetStatePropertyAll(
            AppTypography.textTheme.labelSmall,
          ),
        ),

        // Dialogs
        dialogTheme: DialogTheme(
          elevation: 3,
          shape: AppShapes.dialogShape,
          backgroundColor: AppColors.darkScheme.surfaceContainerHigh,
          titleTextStyle: AppTypography.textTheme.headlineSmall?.copyWith(
            color: AppColors.darkScheme.onSurface,
          ),
          contentTextStyle: AppTypography.textTheme.bodyMedium?.copyWith(
            color: AppColors.darkScheme.onSurfaceVariant,
          ),
        ),

        // Snackbar
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
          ),
          backgroundColor: AppColors.darkScheme.inverseSurface,
          contentTextStyle: AppTypography.textTheme.bodyMedium?.copyWith(
            color: AppColors.darkScheme.onInverseSurface,
          ),
        ),

        // Chips
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
          ),
          labelStyle: AppTypography.textTheme.labelMedium,
        ),

        // Divider
        dividerTheme: DividerThemeData(
          color: AppColors.darkScheme.outlineVariant,
          thickness: 1,
          space: 1,
        ),

        // ListTile
        listTileTheme: ListTileThemeData(
          contentPadding: AppSpacing.listItemPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShapes.radiusSm),
          ),
        ),

        // Page transitions
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      );
}

// ─── Usage in MaterialApp ───────────────────────────────────────────────────
//
// MaterialApp.router(
//   theme: AppTheme.light,
//   darkTheme: AppTheme.dark,
//   themeMode: ThemeMode.system,
//   routerConfig: appRouter,
// );
//
// ─── Accessing Theme in Widgets ─────────────────────────────────────────────
//
// final colorScheme = Theme.of(context).colorScheme;
// final textTheme = Theme.of(context).textTheme;
//
// // Or with the extension from core/extensions:
// final colorScheme = context.colorScheme;
// final textTheme = context.textTheme;
//
// Container(
//   color: colorScheme.primaryContainer,
//   child: Text(
//     'Hello',
//     style: textTheme.headlineMedium?.copyWith(
//       color: colorScheme.onPrimaryContainer,
//     ),
//   ),
// );
