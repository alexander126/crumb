package dev.crumb.ui

import android.app.Activity
import android.app.AlertDialog
import android.app.Application
import android.app.Dialog
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.Editable
import android.text.InputFilter
import android.text.TextWatcher
import android.text.format.Formatter
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbDiagnosticsSnapshot
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbNetworkDiagnostic
import dev.crumb.core.CrumbQueueArtifact
import dev.crumb.core.CrumbReportBuildInput
import dev.crumb.core.CrumbReportQueue
import dev.crumb.core.CrumbReportQueueException
import dev.crumb.core.CrumbReportRuntime
import dev.crumb.core.CrumbReportSettings
import dev.crumb.core.CrumbScreenshotCaptureState
import dev.crumb.core.CrumbScreenshotMaskingState
import dev.crumb.core.CrumbSerializedReportEnvelope
import java.lang.ref.WeakReference
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object CrumbReporter {
    private val categories = listOf("Bug", "Feedback", "Other")
    private val mainHandler = Handler(Looper.getMainLooper())

    private var installedApplication: Application? = null
    private var lifecycleCallbacks: ReporterLifecycleCallbacks? = null
    private var resumedActivity = WeakReference<Activity>(null)
    private var shakeDetector: CrumbShakeDetector? = null
    private var activeSession: ReporterSession? = null

    /** Installs foreground shake invocation and Activity lifecycle recovery. Call once after Crumb.start. */
    @JvmStatic
    fun install(application: Application): Boolean {
        if (Looper.myLooper() != Looper.getMainLooper()) return false
        val settings = runCatching { Crumb.reportSettings() }.getOrNull() ?: return false
        if (installedApplication === application) {
            syncShakeDetection(settings.invocation)
            return true
        }
        if (installedApplication != null) return false

        val callbacks = ReporterLifecycleCallbacks()
        application.registerActivityLifecycleCallbacks(callbacks)
        installedApplication = application
        lifecycleCallbacks = callbacks
        CrumbUploadCoordinator.install(application)
        Thread({
            runCatching { CrumbReportQueue.from(application).recoverInterruptedUploads() }
        }, "Crumb queue recovery").start()
        syncShakeDetection(settings.invocation)
        return true
    }

    @JvmStatic
    @JvmOverloads
    fun show(
        activity: Activity,
        trigger: CrumbInvocation = CrumbInvocation.PROGRAMMATIC,
    ): Boolean {
        val invocationStartedAtNanos = SystemClock.elapsedRealtimeNanos()
        if (Looper.myLooper() != Looper.getMainLooper()) return false
        if (activity.isFinishing || activity.isDestroyed || activeSession != null) return false

        val settings = runCatching { Crumb.reportSettings() }.getOrNull() ?: return false
        if (trigger !in settings.invocation) return false
        ensureInstalled(activity.application)
        CrumbUploadCoordinator.resume(activity.application)
        resumedActivity = WeakReference(activity)

        val session = ReporterSession(
            trigger = trigger,
            triggeredAtMillis = System.currentTimeMillis(),
            location = activity.javaClass.name,
            screenshotArtifact = null,
            screenshotCapture = if (settings.capture.screenshot) {
                CrumbScreenshotCaptureState.UNAVAILABLE
            } else {
                CrumbScreenshotCaptureState.DISABLED_BY_CONFIGURATION
            },
            screenshotMasking = CrumbScreenshotMaskingState.NOT_APPLICABLE,
            settings = settings,
            invocationStartedAtNanos = invocationStartedAtNanos,
        )
        activeSession = session
        presentSession(activity, session)
        startScreenshotCapture(session, activity)
        if (trigger != CrumbInvocation.SHAKE) {
            startDiagnostics(session, activity.applicationContext)
        }
        syncShakeDetection(settings.invocation)
        return true
    }

    private fun ensureInstalled(application: Application) {
        if (installedApplication == null) install(application)
    }

    private fun startDiagnostics(session: ReporterSession, context: android.content.Context) {
        if (session.diagnosticsStarted) return
        session.diagnosticsStarted = true
        Thread({
            val diagnostics = OnDemandDiagnosticsCollector.capture(
                context = context,
                location = session.location,
                options = session.settings.diagnostics,
            )
            CrumbQualityInstrumentation.record(
                CrumbQualityEventKind.DIAGNOSTICS_READY,
                session.invocationStartedAtNanos,
            )
            mainHandler.post {
                if (activeSession !== session || session.finished) return@post
                session.diagnostics = diagnostics
                updateDiagnosticBindings(session)
            }
        }, "Crumb diagnostics").start()
    }

    private fun startScreenshotCapture(session: ReporterSession, activity: Activity) {
        if (!session.settings.capture.screenshot || session.screenshotCaptureStarted) return
        session.screenshotCaptureStarted = true
        CrumbScreenshotArtifactPipeline.captureAsync(
            activity = activity,
            capture = session.settings.capture,
            privacy = session.settings.privacy,
        ) { artifact ->
            if (activeSession !== session || session.finished) return@captureAsync
            session.screenshotArtifact = artifact
            session.screenshotCapture = if (artifact == null) {
                CrumbScreenshotCaptureState.UNAVAILABLE
            } else {
                CrumbScreenshotCaptureState.ENABLED
            }
            session.screenshotMasking = when {
                artifact != null -> artifact.maskingState
                session.settings.privacy.maskAllTextInputs ||
                    session.settings.privacy.maskScreenshotsBeforeUpload -> {
                    CrumbScreenshotMaskingState.FAILED
                }
                else -> CrumbScreenshotMaskingState.NOT_APPLICABLE
            }
            session.screenshotCaptureComplete = true
            CrumbQualityInstrumentation.record(
                CrumbQualityEventKind.SCREENSHOT_READY,
                session.invocationStartedAtNanos,
            )
            renderScreenshotBinding(session)
            updateReviewState(session)
        }
    }

    private fun presentSession(activity: Activity, session: ReporterSession) {
        if (session.finished || activity.isFinishing || activity.isDestroyed) return
        if (session.dialog?.isShowing == true) return
        CrumbDesign.applyAppearance(activity)

        val dialog = Dialog(activity)
        session.dialog = dialog
        session.hostActivity = WeakReference(activity)
        dialog.setOwnerActivity(activity)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setCanceledOnTouchOutside(false)
        dialog.setContentView(
            when (session.screen) {
                ReporterScreen.PROMPT -> buildShakePrompt(activity, dialog, session)
                ReporterScreen.DRAFT -> buildSummary(activity, dialog, session)
                ReporterScreen.FORM -> buildReporter(activity, dialog, session)
            },
        )
        dialog.setOnDismissListener {
            if (session.dialog !== dialog) return@setOnDismissListener
            session.dialog = null
            clearBindings(session)
            val host = session.hostActivity.get()
            session.hostActivity = WeakReference(null)
            if (host?.isChangingConfigurations != true) finishSession(session)
        }
        dialog.setOnKeyListener { _, keyCode, event ->
            if (keyCode != KeyEvent.KEYCODE_BACK || event.action != KeyEvent.ACTION_UP) {
                return@setOnKeyListener false
            }
            if (session.isSaving) return@setOnKeyListener true
            when (session.screen) {
                ReporterScreen.DRAFT -> showReporter(activity, dialog, session)
                ReporterScreen.PROMPT -> finishSession(session)
                ReporterScreen.FORM -> requestFinish(activity, session)
            }
            true
        }
        dialog.show()
        dialog.setCanceledOnTouchOutside(session.screen == ReporterScreen.PROMPT)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            navigationBarColor = CrumbDesign.CANVAS
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                decorView.systemUiVisibility =
                    decorView.systemUiVisibility or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                isNavigationBarContrastEnforced = false
            }
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            attributes = attributes.apply {
                gravity = Gravity.BOTTOM
                width = WindowManager.LayoutParams.MATCH_PARENT
                height = WindowManager.LayoutParams.WRAP_CONTENT
                dimAmount = if (session.screen == ReporterScreen.PROMPT) 0.12f else 0.46f
            }
            decorView.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                decorView.accessibilityPaneTitle = activity.getString(R.string.crumb_report_a_problem)
            }
        }
        if (session.screen == ReporterScreen.FORM && !session.formReadyRecorded) {
            session.formReadyRecorded = true
            CrumbQualityInstrumentation.record(
                CrumbQualityEventKind.FORM_READY,
                session.invocationStartedAtNanos,
            )
        }
    }

    private fun buildShakePrompt(
        activity: Activity,
        dialog: Dialog,
        session: ReporterSession,
    ): View {
        session.screen = ReporterScreen.PROMPT
        return verticalLayout(activity).apply {
            setPadding(dp(activity, 12), 0, dp(activity, 12), dp(activity, 12))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(activity, 16), dp(activity, 16), dp(activity, 16), dp(activity, 16))
                background = CrumbDesign.rounded(
                    activity,
                    CrumbDesign.CANVAS,
                    radius = 20,
                    strokeWidth = 0,
                )
                elevation = dp(activity, 12).toFloat()

                addView(CrumbMarkView(activity, showsTile = true), LinearLayout.LayoutParams(
                    dp(activity, 42),
                    dp(activity, 42),
                ).apply { marginEnd = dp(activity, 13) })

                addView(verticalLayout(activity).apply {
                    addView(text(activity, activity.getString(R.string.crumb_report_a_problem_question), 16f, CrumbDesign.INK).apply {
                        typeface = mediumTypeface()
                        tag = "crumb.shake-prompt-title"
                    })
                    addView(text(
                        activity,
                        activity.getString(R.string.crumb_shake_message),
                        14f,
                        CrumbDesign.SECONDARY_TEXT,
                    ).withMargins(activity, top = 2))
                }, LinearLayout.LayoutParams(
                    0,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    1f,
                ))

                addView(text(activity, activity.getString(R.string.crumb_report), 16f, CrumbDesign.ACCENT_DARK).apply {
                    typeface = mediumTypeface()
                    gravity = Gravity.CENTER
                    setPadding(dp(activity, 12), dp(activity, 10), dp(activity, 12), dp(activity, 10))
                    minimumWidth = dp(activity, 48)
                    minHeight = dp(activity, 48)
                    isClickable = true
                    isFocusable = true
                    tag = "crumb.shake-report"
                    setOnClickListener {
                        dialog.setCanceledOnTouchOutside(false)
                        showReporter(activity, dialog, session)
                        startDiagnostics(session, activity.applicationContext)
                    }
                })
            }, matchWrap())
        }
    }

    private fun buildReporter(
        activity: Activity,
        dialog: Dialog,
        session: ReporterSession,
    ): View {
        session.screen = ReporterScreen.FORM
        val content = verticalLayout(activity).apply {
            background = CrumbDesign.rounded(activity, CrumbDesign.CANVAS, radius = 28, strokeWidth = 0)
            setPadding(dp(activity, 20), dp(activity, 12), dp(activity, 20), dp(activity, 26))
        }

        val grabber = View(activity).apply {
            background = CrumbDesign.rounded(activity, CrumbDesign.DISABLED, radius = 2, strokeWidth = 0)
        }
        content.addView(
            grabber,
            LinearLayout.LayoutParams(dp(activity, 32), dp(activity, 4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(activity, 6)
            },
        )

        val header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val close = text(activity, "×", 22f, CrumbDesign.SECONDARY_TEXT).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            contentDescription = activity.getString(R.string.crumb_close_report)
            isClickable = true
            isFocusable = true
            setOnClickListener { requestFinish(activity, session) }
        }
        header.addView(close, LinearLayout.LayoutParams(dp(activity, 34), dp(activity, 48)))
        val headerTitle = text(activity, activity.getString(R.string.crumb_report_a_problem), 20f, CrumbDesign.INK).apply {
            gravity = Gravity.CENTER_VERTICAL
            typeface = mediumTypeface()
            isFocusable = true
        }
        header.addView(headerTitle, LinearLayout.LayoutParams(0, dp(activity, 48), 1f))
        content.addView(header, matchWrap().withMargins(activity, bottom = 14))

        val category = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            background = CrumbDesign.rounded(
                activity,
                CrumbDesign.CANVAS,
                radius = 99,
                stroke = CrumbDesign.DISABLED,
            )
            contentDescription = activity.getString(R.string.crumb_report_category)
            tag = "crumb.category"
        }
        val categorySegments = categories.mapIndexed { index, _ ->
            text(activity, localizedCategory(activity, index), 14f, CrumbDesign.SECONDARY_TEXT).apply {
                gravity = Gravity.CENTER
                minHeight = dp(activity, 42)
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    session.categoryIndex = index
                    styleCategorySegments(activity, category, session.categoryIndex)
                }
            }
        }
        categorySegments.forEach { segment ->
            category.addView(segment, LinearLayout.LayoutParams(0, dp(activity, 42), 1f))
        }
        styleCategorySegments(activity, category, session.categoryIndex)
        content.addView(category, matchWrap().withMargins(activity, bottom = 18))

        val descriptionField = verticalLayout(activity).apply {
            minimumHeight = dp(activity, 96)
            setPadding(dp(activity, 16), dp(activity, 9), dp(activity, 16), dp(activity, 12))
            background = MaterialDescriptionFieldDrawable(activity)
            addView(text(activity, activity.getString(R.string.crumb_what_happened), 12f, CrumbDesign.ACCENT_DARK))
        }
        val description = EditText(activity).apply {
            setTextColor(CrumbDesign.INK)
            textSize = 16f
            gravity = Gravity.TOP
            minLines = 2
            setText(session.description)
            setPadding(0, dp(activity, 4), 0, 0)
            background = ColorDrawable(Color.TRANSPARENT)
            contentDescription = activity.getString(R.string.crumb_problem_description)
            filters = arrayOf(InputFilter.LengthFilter(4_000))
            tag = "crumb.description"
        }
        descriptionField.addView(description, matchWrap())
        content.addView(descriptionField, matchWrap().withMargins(activity, bottom = 18))

        val screenshotContainer = verticalLayout(activity)
        content.addView(screenshotContainer, matchWrap())
        session.screenshotContainer = screenshotContainer
        renderScreenshotBinding(session)

        val diagnosticsCard = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(activity, 2), 0, dp(activity, 2))
        }
        val statusDot = text(
            activity,
            "●",
            12f,
            if (session.diagnostics == null) CrumbDesign.WARNING else CrumbDesign.ACCENT,
        ).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        diagnosticsCard.addView(statusDot, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { marginEnd = dp(activity, 10) })
        val diagnosticsLabel = text(
            activity,
            if (session.diagnostics == null) {
                activity.getString(R.string.crumb_gathering_context)
            } else {
                activity.getString(
                    R.string.crumb_context_ready_items,
                    diagnosticItemCount(requireNotNull(session.diagnostics)),
                )
            },
            14f,
            CrumbDesign.SECONDARY_TEXT,
        ).apply {
            tag = "crumb.diagnostics-summary"
        }
        val diagnosticsDetail = text(
            activity,
            session.diagnostics?.let { shortDiagnostics(activity, it) }
                ?: activity.getString(R.string.crumb_collecting_context),
            12f,
            CrumbDesign.MUTED_TEXT,
        ).apply { visibility = View.GONE }
        diagnosticsCard.addView(diagnosticsLabel, LinearLayout.LayoutParams(
            0,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            1f,
        ))
        diagnosticsCard.addView(text(
            activity,
            activity.getString(R.string.crumb_view),
            14f,
            CrumbDesign.ACCENT_DARK,
        ).apply {
            typeface = mediumTypeface()
            gravity = Gravity.CENTER
            minHeight = dp(activity, 32)
            minimumWidth = dp(activity, 48)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                val detail = session.diagnostics?.let { shortDiagnostics(activity, it) }
                    ?: activity.getString(R.string.crumb_collecting_context)
                AlertDialog.Builder(activity)
                    .setTitle(activity.getString(R.string.crumb_context_ready))
                    .setMessage(detail)
                    .setPositiveButton(activity.getString(R.string.crumb_ok), null)
                    .show()
            }
        })
        content.addView(diagnosticsCard, matchWrap().withMargins(activity, bottom = 10))

        val review = Button(activity).apply {
            CrumbDesign.stylePrimaryButton(activity, this, activity.getString(R.string.crumb_review_report))
            isEnabled = session.description.isNotBlank() && session.diagnostics != null &&
                session.screenshotCaptureComplete
            tag = "crumb.review-draft"
            setOnClickListener { showSummary(activity, dialog, session) }
        }
        description.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(value: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(value: CharSequence?, start: Int, before: Int, count: Int) {
                session.description = value?.toString().orEmpty()
                updateReviewState(session)
            }

            override fun afterTextChanged(value: Editable?) = Unit
        })
        content.addView(review, matchWrap())
        val actionHelper = text(
            activity,
            if (session.description.isBlank()) {
                activity.getString(R.string.crumb_add_description)
            } else if (session.diagnostics == null) {
                activity.getString(R.string.crumb_finishing_context)
            } else if (!session.screenshotCaptureComplete) {
                activity.getString(R.string.crumb_preparing_screenshot)
            } else {
                activity.getString(R.string.crumb_ready_to_review)
            },
            12f,
            CrumbDesign.MUTED_TEXT,
        ).apply { gravity = Gravity.CENTER }
        actionHelper.visibility = if (
            session.description.isNotBlank() && session.diagnostics != null &&
                session.screenshotCaptureComplete
        ) View.GONE else View.VISIBLE
        content.addView(actionHelper, matchWrap().withMargins(activity, top = 7))

        session.diagnosticsLabel = diagnosticsLabel
        session.diagnosticsDetailLabel = diagnosticsDetail
        session.diagnosticsStatusDot = statusDot
        session.reviewButton = review
        session.actionHelperLabel = actionHelper
        mainHandler.post {
            if (session.dialog === dialog) headerTitle.sendAccessibilityEvent(
                android.view.accessibility.AccessibilityEvent.TYPE_VIEW_FOCUSED,
            )
        }
        return ScrollView(activity).apply {
            isFillViewport = true
            addView(content)
        }
    }

    private fun showSummary(activity: Activity, dialog: Dialog, session: ReporterSession) {
        val diagnostics = session.diagnostics ?: return
        val envelope = runCatching { buildEnvelope(session, diagnostics) }.getOrElse {
            val content = verticalLayout(activity).apply {
                setPadding(dp(activity, 24), dp(activity, 24), dp(activity, 24), dp(activity, 32))
                addView(text(activity, activity.getString(R.string.crumb_draft_failed_title), 28f, CrumbDesign.INK))
                addView(text(
                    activity,
                    activity.getString(R.string.crumb_draft_failed_message),
                    16f,
                    Color.RED,
                ).withMargins(activity, top = 18, bottom = 18))
                addView(Button(activity).apply {
                    text = activity.getString(R.string.crumb_done)
                    setOnClickListener { finishSession(session) }
                }, matchWrap())
            }
            dialog.setContentView(ScrollView(activity).apply { addView(content) })
            return
        }

        session.envelope = envelope
        session.screen = ReporterScreen.DRAFT
        clearBindings(session)
        dialog.setContentView(buildSummary(activity, dialog, session))
    }

    private fun showReporter(activity: Activity, dialog: Dialog, session: ReporterSession) {
        clearBindings(session)
        session.screen = ReporterScreen.FORM
        dialog.setCanceledOnTouchOutside(false)
        dialog.setContentView(buildReporter(activity, dialog, session))
    }

    private fun requestFinish(activity: Activity, session: ReporterSession) {
        val hasMeaningfulInput = session.categoryIndex != 0 || session.description.isNotBlank()
        if (!hasMeaningfulInput) {
            finishSession(session)
            return
        }

        AlertDialog.Builder(activity)
            .setTitle(activity.getString(R.string.crumb_discard_title))
            .setMessage(activity.getString(R.string.crumb_discard_message))
            .setNegativeButton(activity.getString(R.string.crumb_keep_editing), null)
            .setPositiveButton(activity.getString(R.string.crumb_discard_report)) { _, _ -> finishSession(session) }
            .show()
    }

    private fun buildEnvelope(
        session: ReporterSession,
        diagnostics: CrumbDiagnosticsSnapshot,
    ): CrumbSerializedReportEnvelope {
        val deviceFamily = listOf(Build.MANUFACTURER, Build.MODEL)
            .filter(String::isNotBlank)
            .joinToString(" ")
            .ifBlank { "Android device" }
            .take(128)

        return Crumb.buildReport(
            CrumbReportBuildInput(
                reportId = Crumb.newReportId(),
                trigger = session.trigger,
                triggeredAtMillis = session.triggeredAtMillis,
                submittedAtMillis = System.currentTimeMillis(),
                runtime = CrumbReportRuntime(
                    osVersion = "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})".take(64),
                    deviceFamily = deviceFamily,
                    locale = Locale.getDefault().toLanguageTag().ifBlank { "und" }.take(64),
                    timezone = TimeZone.getDefault().id.take(128),
                ),
                category = categories.getOrElse(session.categoryIndex) { categories.first() },
                description = session.description.trim(),
                diagnostics = diagnostics,
                screenshotCapture = session.screenshotCapture,
                screenshotMasking = session.screenshotMasking,
                artifacts = session.screenshotArtifact?.let { listOf(it.manifest) }.orEmpty(),
            ),
        )
    }

    private fun buildSummary(activity: Activity, dialog: Dialog, session: ReporterSession): View {
        val diagnostics = requireNotNull(session.diagnostics)
        val envelope = requireNotNull(session.envelope)
        val category = categories.getOrElse(session.categoryIndex) { categories.first() }
        val hasScreenshot = session.screenshotArtifact != null
        val content = verticalLayout(activity).apply {
            background = CrumbDesign.rounded(activity, CrumbDesign.CANVAS, radius = 28, strokeWidth = 0)
            setPadding(dp(activity, 20), dp(activity, 12), dp(activity, 20), dp(activity, 26))
        }

        content.addView(
            View(activity).apply {
                background = CrumbDesign.rounded(activity, CrumbDesign.DISABLED, radius = 2, strokeWidth = 0)
            },
            LinearLayout.LayoutParams(dp(activity, 32), dp(activity, 4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(activity, 6)
            },
        )
        val header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(text(activity, "←", 20f, CrumbDesign.SECONDARY_TEXT).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            contentDescription = activity.getString(R.string.crumb_back_to_report)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                if (!session.isSaving) showReporter(activity, dialog, session)
            }
        }, LinearLayout.LayoutParams(dp(activity, 34), dp(activity, 48)))
        header.addView(text(activity, activity.getString(R.string.crumb_review), 20f, CrumbDesign.INK).apply {
            gravity = Gravity.CENTER_VERTICAL
            typeface = mediumTypeface()
        }, LinearLayout.LayoutParams(0, dp(activity, 48), 1f))
        content.addView(header, matchWrap().withMargins(activity, bottom = 12))

        val localBanner = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            setPadding(dp(activity, 14), dp(activity, 12), dp(activity, 14), dp(activity, 12))
            background = CrumbDesign.rounded(activity, CrumbDesign.MUTED_SURFACE, radius = 12, strokeWidth = 0)
            addView(text(activity, "●", 12f, CrumbDesign.INK).apply {
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = dp(activity, 10) })
            addView(text(
                activity,
                activity.getString(R.string.crumb_local_only),
                13.5f,
                CrumbDesign.SECONDARY_TEXT,
            ), LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f,
            ))
        }
        localBanner.contentDescription =
            activity.getString(R.string.crumb_local_only)
        content.addView(localBanner, matchWrap().withMargins(activity, bottom = 16))

        val reportCard = verticalLayout(activity).apply {
            addView(text(
                activity,
                activity.getString(
                    R.string.crumb_your_report,
                    localizedCategory(activity, session.categoryIndex).uppercase(),
                ),
                10f,
                CrumbDesign.TERTIARY_TEXT,
            ).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                letterSpacing = 0.1f
            })
            addView(text(activity, session.description, 15.5f, CrumbDesign.INK).withMargins(activity, top = 6))
        }
        content.addView(reportCard, matchWrap().withMargins(activity, bottom = 14))

        val attachmentCard = verticalLayout(activity).apply {
            addView(View(activity).apply {
                setBackgroundColor(CrumbDesign.DIVIDER)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(activity, 1)))
            addView(text(activity, activity.getString(R.string.crumb_whats_attached), 10f, CrumbDesign.TERTIARY_TEXT).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                letterSpacing = 0.1f
            }.withMargins(activity, top = 12, bottom = 5))
        }
        val appVersion = runCatching {
            val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
            val build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION") info.versionCode.toLong()
            }
            "${info.versionName ?: activity.getString(R.string.crumb_unavailable)} ($build)"
        }.getOrDefault(activity.getString(R.string.crumb_unavailable))
        addAttachmentRow(activity, attachmentCard, activity.getString(R.string.crumb_app_release), appVersion)
        addAttachmentRow(activity, attachmentCard, activity.getString(R.string.crumb_screen), diagnostics.location)
        addAttachmentRow(
            activity,
            attachmentCard,
            activity.getString(R.string.crumb_device_and_os),
            "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE}",
        )
        addAttachmentRow(
            activity,
            attachmentCard,
            activity.getString(R.string.crumb_app_logs),
            activity.getString(R.string.crumb_app_provided_only),
        )
        val unavailableCount = listOf(
            diagnostics.cpuUsagePercent,
            diagnostics.residentMemoryBytes,
            diagnostics.physicalFootprintBytes,
            diagnostics.network.healthCheck,
        ).count { it == null }
        addAttachmentRow(
            activity,
            attachmentCard,
            activity.getString(R.string.crumb_not_available),
            activity.resources.getQuantityString(
                R.plurals.crumb_items,
                unavailableCount,
                unavailableCount,
            ),
            isLast = true,
        )
        content.addView(attachmentCard, matchWrap().withMargins(activity, bottom = 14))

        val summary = buildString {
            appendLine("LOCAL ONLY — NOT UPLOADED")
            appendLine()
            appendLine("Envelope: ${envelope.reportId}")
            appendLine("Serialized size: ${envelope.json.toByteArray(Charsets.UTF_8).size} bytes")
            appendLine("Category: $category")
            appendLine("Description: ${session.description}")
            appendLine("Screenshot: ${if (hasScreenshot) "captured for this report" else "not captured"}")
            appendLine()
            appendLine("ON-DEMAND DIAGNOSTICS")
            appendLine("Captured: ${iso8601(diagnostics.capturedAtMillis)}")
            appendLine("Location: ${diagnostics.location}")
            appendLine("Process: ${diagnostics.processName} (${diagnostics.processId})")
            appendLine("CPU: ${diagnostics.cpuUsagePercent?.let { "%.1f%%".format(Locale.US, it) } ?: "unavailable"}")
            appendLine("Resident memory: ${byteCount(activity, diagnostics.residentMemoryBytes)}")
            appendLine("Physical footprint: ${byteCount(activity, diagnostics.physicalFootprintBytes)}")
            appendLine("Thermal state: ${diagnostics.thermalState}")
            appendLine("Threads: ${diagnostics.threadCount}")
            appendLine("GPU: ${diagnostics.gpuStatus}")
            appendLine("Network: ${networkSummary(diagnostics.network)}")
            diagnostics.network.healthCheck?.let { health ->
                val outcome = if (health.succeeded) "available" else "unavailable"
                val status = health.statusCode?.toString() ?: "no status"
                val failure = health.failure?.let { " · $it" }.orEmpty()
                appendLine("Crumb API: ${health.host} · $outcome · $status · ${health.latencyMilliseconds} ms$failure")
            } ?: appendLine("Crumb API: not configured")

            val logSources = diagnostics.logs.sources.ifEmpty { listOf("none") }.joinToString()
            appendLine(
                "Logs: ${diagnostics.logs.status.name.lowercase()} · " +
                    "${diagnostics.logs.entries.size} entries · $logSources",
            )
            if (diagnostics.logs.truncated) {
                appendLine("Logs truncated: ${diagnostics.logs.droppedEntryCount} entries omitted")
            }
            diagnostics.logs.failures.forEach { appendLine("Log source warning: $it") }
            appendLine(
                "Live stacks: ${diagnostics.stackTraces.status.name.lowercase()} · " +
                    "${diagnostics.stackTraces.scope} · ${diagnostics.stackTraces.threads.size} threads",
            )
            diagnostics.stackTraces.unavailableReason?.let {
                appendLine("Live stack reason: $it")
            }

            if (diagnostics.busiestThreads.isNotEmpty()) {
                appendLine()
                appendLine("BUSIEST APP THREADS")
                diagnostics.busiestThreads.forEach { thread ->
                    val cpu = thread.cpuUsagePercent?.let { "%.1f%%".format(Locale.US, it) }
                        ?: "unavailable"
                    appendLine("#${thread.id} ${thread.name} · ${thread.state} · $cpu")
                }
            }
            if (diagnostics.logs.entries.isNotEmpty()) {
                appendLine()
                appendLine("RECENT APP LOGS")
                diagnostics.logs.entries.forEach { entry ->
                    appendLine(
                        "${iso8601(entry.timestampMillis)} [${entry.level.name}] " +
                            "${entry.source}/${entry.category} · ${entry.message}",
                    )
                }
            }
            if (diagnostics.stackTraces.threads.isNotEmpty()) {
                appendLine()
                appendLine("LIVE THREAD STACKS")
                diagnostics.stackTraces.threads.forEach { thread ->
                    appendLine("#${thread.id} ${thread.name} · ${thread.state}")
                    thread.frames.forEach { appendLine("  $it") }
                }
            }
            appendLine()
            appendLine("SERIALIZED REPORT ENVELOPE")
            appendLine(envelope.json)
        }
        val technicalDetail = text(activity, summary, 14f, Color.DKGRAY).apply {
            typeface = android.graphics.Typeface.MONOSPACE
            tag = "crumb.draft-summary"
            setTextColor(CrumbDesign.TEXT_ON_DARK)
            setPadding(dp(activity, 14), dp(activity, 14), dp(activity, 14), dp(activity, 14))
            background = CrumbDesign.rounded(
                activity,
                CrumbDesign.DARK_SURFACE,
                strokeWidth = 0,
            )
            visibility = View.GONE
        }
        content.addView(technicalDetail, matchWrap())
        content.addView(Button(activity).apply {
            CrumbDesign.stylePrimaryButton(
                activity,
                this,
                if (session.isSaving) {
                    activity.getString(R.string.crumb_saving_locally)
                } else {
                    activity.getString(R.string.crumb_submit_report)
                },
            )
            isEnabled = !session.isSaving
            tag = "crumb.submit-report"
            setOnClickListener { submitReport(activity, session, this) }
        }, matchWrap())
        content.addView(text(
            activity,
            activity.getString(R.string.crumb_android_privacy_note),
            12.5f,
            CrumbDesign.MUTED_TEXT,
        ).apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
        }, matchWrap().withMargins(activity, top = 8))
        return ScrollView(activity).apply {
            isFillViewport = true
            addView(content)
        }
    }

    private fun submitReport(activity: Activity, session: ReporterSession, button: Button) {
        if (session.isSaving) return
        val envelope = session.envelope ?: return
        session.isSaving = true
        button.isEnabled = false
        CrumbDesign.stylePrimaryButton(activity, button, activity.getString(R.string.crumb_saving_locally))
        button.announceForAccessibility(activity.getString(R.string.crumb_saving_announcement))
        val applicationContext = activity.applicationContext
        val artifacts = session.screenshotArtifact?.let {
            listOf(CrumbQueueArtifact(it.manifest, it.encodedBytes))
        }.orEmpty()

        Thread({
            val result = runCatching {
                CrumbReportQueue.from(applicationContext).enqueue(envelope, artifacts)
            }
            mainHandler.post {
                session.isSaving = false
                val host = session.hostActivity.get()
                val currentDialog = session.dialog
                if (activeSession !== session || session.finished || host == null ||
                    host.isFinishing || host.isDestroyed || currentDialog == null
                ) {
                    return@post
                }
                result.fold(
                    onSuccess = {
                        CrumbUploadCoordinator.reportDidQueue()
                        AlertDialog.Builder(host)
                            .setTitle(host.getString(R.string.crumb_report_saved))
                            .setMessage(
                                host.getString(R.string.crumb_report_saved_message),
                            )
                            .setCancelable(false)
                            .setPositiveButton(host.getString(R.string.crumb_done)) { _, _ -> finishSession(session) }
                            .show()
                    },
                    onFailure = { error ->
                        currentDialog.setContentView(buildSummary(host, currentDialog, session))
                        val message = if (error is CrumbReportQueueException.QueueFull) {
                            host.getString(R.string.crumb_queue_full)
                        } else {
                            host.getString(R.string.crumb_save_failed)
                        }
                        AlertDialog.Builder(host)
                            .setTitle(host.getString(R.string.crumb_save_failed_title))
                            .setMessage(message)
                            .setPositiveButton(host.getString(R.string.crumb_ok), null)
                            .show()
                    },
                )
            }
        }, "Crumb local report commit").start()
    }

    private fun showScreenshotPreview(activity: Activity, bitmap: Bitmap) {
        val previewDialog = Dialog(activity, android.R.style.Theme_DeviceDefault_NoActionBar_Fullscreen)
        val content = verticalLayout(activity).apply {
            setBackgroundColor(Color.BLACK)
            setPadding(dp(activity, 12), dp(activity, 12), dp(activity, 12), dp(activity, 12))
        }
        content.addView(text(activity, activity.getString(R.string.crumb_close), 16f, Color.WHITE).apply {
            gravity = Gravity.CENTER
            typeface = mediumTypeface()
            isClickable = true
            isFocusable = true
            contentDescription = activity.getString(R.string.crumb_close_preview)
            setOnClickListener { previewDialog.dismiss() }
        }, LinearLayout.LayoutParams(dp(activity, 72), dp(activity, 48)).apply {
            gravity = Gravity.END
        })
        content.addView(ImageView(activity).apply {
            setImageBitmap(bitmap)
            scaleType = ImageView.ScaleType.FIT_CENTER
            contentDescription = activity.getString(R.string.crumb_screenshot_preview)
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f,
        ))
        previewDialog.setContentView(content)
        previewDialog.show()
    }

    private fun updateDiagnosticBindings(session: ReporterSession) {
        val diagnostics = session.diagnostics ?: return
        val activity = session.hostActivity.get() ?: return
        val summary = shortDiagnostics(activity, diagnostics)
        session.diagnosticsLabel?.apply {
            text = activity.getString(
                R.string.crumb_context_ready_items,
                diagnosticItemCount(diagnostics),
            )
            contentDescription = "Context ready. $summary"
            announceForAccessibility(activity.getString(R.string.crumb_context_ready_announcement))
        }
        session.diagnosticsDetailLabel?.text = summary
        session.diagnosticsStatusDot?.setTextColor(CrumbDesign.ACCENT)
        updateReviewState(session)
    }

    private fun renderScreenshotBinding(session: ReporterSession) {
        val container = session.screenshotContainer ?: return
        val activity = session.hostActivity.get() ?: return
        container.removeAllViews()
        val bitmap = session.screenshotArtifact?.preview ?: return
        val screenshotCard = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(activity, 14), dp(activity, 12), dp(activity, 14), dp(activity, 12))
            background = CrumbDesign.rounded(activity, CrumbDesign.MUTED_SURFACE, strokeWidth = 0)
        }
        val preview = ImageView(activity).apply {
            tag = "crumb.screenshot-preview"
            setImageBitmap(bitmap)
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = CrumbDesign.rounded(
                activity,
                CrumbDesign.DARK_SURFACE,
                radius = 9,
                strokeWidth = 0,
            )
            clipToOutline = true
            contentDescription = activity.getString(R.string.crumb_screenshot_preview)
            isClickable = true
            isFocusable = true
            setOnClickListener { showScreenshotPreview(activity, bitmap) }
        }
        screenshotCard.addView(preview, LinearLayout.LayoutParams(dp(activity, 42), dp(activity, 56)))
        val screenshotCopy = verticalLayout(activity).apply {
            setPadding(dp(activity, 14), 0, 0, 0)
            addView(text(activity, activity.getString(R.string.crumb_screenshot_attached), 15f, CrumbDesign.INK).apply {
                typeface = mediumTypeface()
            })
            addView(text(
                activity,
                if (session.screenshotMasking == CrumbScreenshotMaskingState.APPLIED) {
                    activity.getString(R.string.crumb_screenshot_masked_preview)
                } else {
                    activity.getString(R.string.crumb_tap_to_preview)
                },
                12f,
                CrumbDesign.MUTED_TEXT,
            ).withMargins(activity, top = 3))
            isClickable = true
            isFocusable = true
            setOnClickListener { showScreenshotPreview(activity, bitmap) }
        }
        screenshotCard.addView(
            screenshotCopy,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        screenshotCard.addView(text(activity, activity.getString(R.string.crumb_remove), 14f, CrumbDesign.ACCENT_DARK).apply {
            typeface = mediumTypeface()
            gravity = Gravity.CENTER
            minimumWidth = dp(activity, 48)
            minHeight = dp(activity, 48)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                session.screenshotArtifact = null
                container.removeAllViews()
            }
        })
        container.addView(screenshotCard, matchWrap().withMargins(activity, bottom = 18))
    }

    private fun updateReviewState(session: ReporterSession) {
        val activity = session.hostActivity.get() ?: return
        val hasDescription = session.description.isNotBlank()
        val isReady = hasDescription && session.diagnostics != null &&
            session.screenshotCaptureComplete
        session.reviewButton?.isEnabled = isReady
        session.actionHelperLabel?.text = when {
            !hasDescription -> activity.getString(R.string.crumb_add_description)
            session.diagnostics == null -> activity.getString(R.string.crumb_finishing_context)
            !session.screenshotCaptureComplete -> activity.getString(R.string.crumb_preparing_screenshot)
            else -> activity.getString(R.string.crumb_ready_to_review)
        }
        session.actionHelperLabel?.visibility = if (isReady) View.GONE else View.VISIBLE
    }

    private fun detachForRecreation(session: ReporterSession) {
        val dialog = session.dialog
        session.dialog = null
        session.hostActivity = WeakReference(null)
        clearBindings(session)
        dialog?.setOnDismissListener(null)
        if (dialog?.isShowing == true) dialog.dismiss()
    }

    private fun finishSession(session: ReporterSession) {
        if (session.finished) return
        session.finished = true
        if (activeSession === session) activeSession = null
        val dialog = session.dialog
        session.dialog = null
        session.hostActivity = WeakReference(null)
        clearBindings(session)
        dialog?.setOnDismissListener(null)
        if (dialog?.isShowing == true) dialog.dismiss()
        CrumbQualityInstrumentation.record(
            CrumbQualityEventKind.REPORTER_CLOSED,
            session.invocationStartedAtNanos,
        )
        val invocation = runCatching { Crumb.reportSettings().invocation }.getOrDefault(emptySet())
        syncShakeDetection(invocation)
    }

    private fun clearBindings(session: ReporterSession) {
        session.diagnosticsLabel = null
        session.diagnosticsDetailLabel = null
        session.diagnosticsStatusDot = null
        session.reviewButton = null
        session.actionHelperLabel = null
        session.screenshotContainer = null
    }

    private fun handleActivityResumed(activity: Activity) {
        resumedActivity = WeakReference(activity)
        val session = activeSession
        if (session != null && session.dialog == null) presentSession(activity, session)
        val invocation = runCatching { Crumb.reportSettings().invocation }.getOrDefault(emptySet())
        syncShakeDetection(invocation)
    }

    private fun handleActivityPaused(activity: Activity) {
        if (resumedActivity.get() === activity) resumedActivity = WeakReference(null)
        stopShakeDetection()
        val session = activeSession
        if (session?.hostActivity?.get() === activity && activity.isChangingConfigurations) {
            detachForRecreation(session)
        }
    }

    private fun handleActivityDestroyed(activity: Activity) {
        val session = activeSession ?: return
        if (session.hostActivity.get() !== activity) return
        if (activity.isChangingConfigurations) {
            detachForRecreation(session)
        } else {
            finishSession(session)
        }
    }

    private fun syncShakeDetection(invocation: Set<CrumbInvocation>) {
        stopShakeDetection()
        val activity = resumedActivity.get() ?: return
        if (activeSession != null || CrumbInvocation.SHAKE !in invocation) return
        shakeDetector = CrumbShakeDetector(activity.applicationContext) {
            mainHandler.post {
                val resumed = resumedActivity.get() ?: return@post
                if (activeSession == null) show(resumed, CrumbInvocation.SHAKE)
            }
        }.also(CrumbShakeDetector::start)
    }

    private fun stopShakeDetection() {
        shakeDetector?.stop()
        shakeDetector = null
    }

    private fun shortDiagnostics(activity: Activity, diagnostics: CrumbDiagnosticsSnapshot): String {
        val cpu = diagnostics.cpuUsagePercent?.let { "%.1f%% CPU".format(Locale.US, it) }
            ?: "CPU unavailable"
        val memory = byteCount(activity, diagnostics.residentMemoryBytes)
        val connection = listOfNotNull(
            diagnostics.network.cellularGeneration,
            diagnostics.network.transport,
        ).joinToString(" · ")
        return "$cpu · $memory · $connection ${diagnostics.network.status} · " +
            "${diagnostics.logs.entries.size} recent logs"
    }

    @Suppress("UNUSED_PARAMETER")
    private fun diagnosticItemCount(diagnostics: CrumbDiagnosticsSnapshot): Int = 22

    private fun networkSummary(network: CrumbNetworkDiagnostic): String {
        val parts = mutableListOf(network.status, network.transport)
        network.cellularGeneration?.let(parts::add)
        if (network.isExpensive) parts += "expensive"
        if (network.isConstrained) parts += "constrained"
        return parts.joinToString(" · ")
    }

    private fun localizedCategory(activity: Activity, index: Int): String = when (index) {
        1 -> activity.getString(R.string.crumb_category_feedback)
        2 -> activity.getString(R.string.crumb_category_other)
        else -> activity.getString(R.string.crumb_category_bug)
    }

    private fun byteCount(activity: Activity, bytes: Long?): String {
        return bytes?.let { Formatter.formatShortFileSize(activity, it) } ?: "unavailable"
    }

    private fun iso8601(milliseconds: Long): String {
        return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date(milliseconds))
    }

    private fun styleCategorySegments(
        activity: Activity,
        container: LinearLayout,
        selectedIndex: Int,
    ) {
        for (index in 0 until container.childCount) {
            val segment = container.getChildAt(index) as? TextView ?: continue
            val selected = index == selectedIndex
            segment.isSelected = selected
            segment.setTextColor(if (selected) CrumbDesign.TEXT_ON_SELECTED else CrumbDesign.SECONDARY_TEXT)
            segment.typeface = if (selected) {
                mediumTypeface()
            } else {
                android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.NORMAL)
            }
            segment.background = if (selected) {
                CrumbDesign.rounded(
                    activity,
                    CrumbDesign.SELECTED_FILL,
                    radius = 99,
                    strokeWidth = 0,
                )
            } else {
                ColorDrawable(Color.TRANSPARENT)
            }
            segment.contentDescription = activity.getString(
                R.string.crumb_category_accessibility,
                localizedCategory(activity, index),
                if (selected) activity.getString(R.string.crumb_selected_suffix) else "",
            )
        }
    }

    private fun addAttachmentRow(
        activity: Activity,
        container: LinearLayout,
        title: String,
        value: String,
        isLast: Boolean = false,
    ) {
        if (isLast) {
            container.addView(View(activity).apply {
                setBackgroundColor(CrumbDesign.DIVIDER)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(activity, 1)).apply {
                topMargin = dp(activity, 3)
            })
        }
        container.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(activity, 3), 0, dp(activity, 3))
            addView(text(activity, title, 14f, CrumbDesign.SECONDARY_TEXT), LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1f,
            ))
            addView(text(activity, value, 12f, CrumbDesign.INK).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                gravity = Gravity.END
                maxLines = 1
            }, LinearLayout.LayoutParams(
                0,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                1.4f,
            ))
        }, matchWrap())
    }

    private fun verticalLayout(activity: Activity) = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }

    private fun text(activity: Activity, value: String, size: Float, color: Int) = TextView(activity).apply {
        text = value
        textSize = size
        setTextColor(color)
    }

    private fun mediumTypeface() = android.graphics.Typeface.create(
        "sans-serif-medium",
        android.graphics.Typeface.NORMAL,
    )

    private fun matchWrap() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    private fun <T : View> T.withMargins(
        activity: Activity,
        top: Int = 0,
        bottom: Int = 0,
    ): T {
        layoutParams = matchWrap().apply {
            topMargin = dp(activity, top)
            bottomMargin = dp(activity, bottom)
        }
        return this
    }

    private fun LinearLayout.LayoutParams.withMargins(
        activity: Activity,
        top: Int = 0,
        bottom: Int = 0,
    ) = apply {
        topMargin = dp(activity, top)
        bottomMargin = dp(activity, bottom)
    }

    private fun dp(activity: Activity, value: Int) =
        (value * activity.resources.displayMetrics.density).toInt()

    private class ReporterLifecycleCallbacks : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            CrumbUploadCoordinator.resume(activity.application)
            handleActivityResumed(activity)
        }

        override fun onActivityPaused(activity: Activity) {
            CrumbUploadCoordinator.pause()
            handleActivityPaused(activity)
        }
        override fun onActivityDestroyed(activity: Activity) = handleActivityDestroyed(activity)
        override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    }

    private enum class ReporterScreen { PROMPT, FORM, DRAFT }

    private class ReporterSession(
        val trigger: CrumbInvocation,
        val triggeredAtMillis: Long,
        val location: String,
        var screenshotArtifact: CrumbScreenshotArtifact?,
        var screenshotCapture: CrumbScreenshotCaptureState,
        var screenshotMasking: CrumbScreenshotMaskingState,
        val settings: CrumbReportSettings,
        val invocationStartedAtNanos: Long,
    ) {
        var categoryIndex = 0
        var description = ""
        var diagnostics: CrumbDiagnosticsSnapshot? = null
        var envelope: CrumbSerializedReportEnvelope? = null
        var screen = if (trigger == CrumbInvocation.SHAKE) {
            ReporterScreen.PROMPT
        } else {
            ReporterScreen.FORM
        }
        var dialog: Dialog? = null
        var hostActivity = WeakReference<Activity>(null)
        var diagnosticsLabel: TextView? = null
        var diagnosticsDetailLabel: TextView? = null
        var diagnosticsStatusDot: TextView? = null
        var reviewButton: Button? = null
        var actionHelperLabel: TextView? = null
        var screenshotContainer: LinearLayout? = null
        var diagnosticsStarted = false
        var screenshotCaptureStarted = !settings.capture.screenshot
        var screenshotCaptureComplete = !settings.capture.screenshot
        var formReadyRecorded = false
        var isSaving = false
        var finished = false
    }
}

private class MaterialDescriptionFieldDrawable(context: Context) : Drawable() {
    private val density = context.resources.displayMetrics.density
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = CrumbDesign.MUTED_SURFACE }
    private val accent = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = CrumbDesign.ACCENT }

    override fun draw(canvas: Canvas) {
        val rect = RectF(bounds)
        val radius = 6f * density
        canvas.drawRoundRect(rect, radius, radius, fill)
        canvas.drawRect(rect.left, rect.bottom - radius, rect.right, rect.bottom, fill)
        canvas.drawRect(rect.left, rect.bottom - 2f * density, rect.right, rect.bottom, accent)
    }

    override fun setAlpha(alpha: Int) {
        fill.alpha = alpha
        accent.alpha = alpha
    }

    override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {
        fill.colorFilter = colorFilter
        accent.colorFilter = colorFilter
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun getOpacity(): Int = android.graphics.PixelFormat.TRANSLUCENT
}

private class CrumbMarkView(
    context: Context,
    private val showsTile: Boolean = false,
) : View(context) {
    private val density = context.resources.displayMetrics.density
    private val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = CrumbDesign.MARK_BACKGROUND
    }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = if (showsTile) Color.WHITE else CrumbDesign.INK
    }
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = CrumbDesign.ACCENT
        style = Paint.Style.STROKE
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (showsTile) {
            val bounds = RectF(0f, 0f, width.toFloat(), height.toFloat())
            canvas.drawRoundRect(bounds, 11f * density, 11f * density, backgroundPaint)
        }

        val glyphSize = 24f * density
        val glyphScale = glyphSize / 64f
        val originX = (width - glyphSize) / 2f
        val originY = (height - glyphSize) / 2f
        val points = arrayOf(
            12f to 12f, 32f to 12f, 52f to 12f,
            12f to 32f, 52f to 32f,
            12f to 52f, 32f to 52f, 52f to 52f,
        )
        val dotRadius = 5.5f * glyphScale
        points.forEach { (x, y) ->
            canvas.drawCircle(originX + x * glyphScale, originY + y * glyphScale, dotRadius, dotPaint)
        }
        ringPaint.strokeWidth = 6f * glyphScale
        canvas.drawCircle(
            originX + 32f * glyphScale,
            originY + 32f * glyphScale,
            8.5f * glyphScale,
            ringPaint,
        )
    }
}
