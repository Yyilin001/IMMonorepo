package com.xmtx.imappandroid.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val DarkColorScheme = darkColorScheme(
    primary = BrandBlue,
    secondary = BrandGreen,
    tertiary = BrandRose,
    background = Color(0xFF0F172A),
    surface = Color(0xFF111827),
)

private val LightColorScheme = lightColorScheme(
    primary = BrandBlue,
    secondary = BrandGreen,
    tertiary = BrandRose,
    background = SurfaceLight,
    surface = Color.White,
    onBackground = InkDark,
    onSurface = InkDark,
)

@Composable
fun IMAppAndroidTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme,
        typography = Typography,
        content = content,
    )
}
