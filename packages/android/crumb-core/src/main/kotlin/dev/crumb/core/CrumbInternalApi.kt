package dev.crumb.core

/**
 * Marks a declaration that exists only so Crumb's own modules can share it -
 * today, so `crumb-react-native` can carry the React Native JavaScript crash
 * handoff without `crumb-core` shipping it to native-only consumers.
 *
 * It is not part of the supported SDK surface. It may change or disappear in
 * any release, and opting in means accepting that.
 */
@RequiresOptIn(
    level = RequiresOptIn.Level.ERROR,
    message = "Internal to Crumb's own modules. Not a supported API; it may change in any release.",
)
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION, AnnotationTarget.PROPERTY)
annotation class CrumbInternalApi
