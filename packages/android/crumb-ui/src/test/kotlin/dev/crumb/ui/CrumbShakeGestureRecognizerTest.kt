package dev.crumb.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrumbShakeGestureRecognizerTest {
    @Test
    fun requiresTwoHitsInsideWindow() {
        val recognizer = CrumbShakeGestureRecognizer()

        assertFalse(recognizer.record(2.5f, 1_000))
        assertTrue(recognizer.record(2.5f, 1_400))
    }

    @Test
    fun rejectsSeparatedHitsAndCooldownDuplicates() {
        val recognizer = CrumbShakeGestureRecognizer()

        assertFalse(recognizer.record(2.5f, 1_000))
        assertFalse(recognizer.record(2.5f, 1_700))
        assertTrue(recognizer.record(2.5f, 1_900))
        assertFalse(recognizer.record(2.5f, 2_100))
        assertFalse(recognizer.record(2.5f, 2_300))
        assertFalse(recognizer.record(2.5f, 3_600))
        assertTrue(recognizer.record(2.5f, 3_800))
    }

    @Test
    fun ignoresSubThresholdMotion() {
        val recognizer = CrumbShakeGestureRecognizer()

        assertFalse(recognizer.record(1.9f, 1_000))
        assertFalse(recognizer.record(2.1f, 1_200))
    }
}
