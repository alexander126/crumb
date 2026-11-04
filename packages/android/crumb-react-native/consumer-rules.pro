# Preserve source locations so Crumb failures remain actionable after host-app shrinking.
-keepattributes SourceFile,LineNumberTable

# Report serialization records enum names as stable wire values.
-keepclassmembers enum dev.crumb.core.** {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
