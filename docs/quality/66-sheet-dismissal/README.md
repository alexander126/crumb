# Report-sheet dismissal evidence

These sanitized public visual fixtures were explicitly requested for issue #66.
They use only the disposable native demo and synthetic input, with upload disabled.

## Android API 26

- [Drag and backdrop recording](android-dismissal.gif): open the sheet, drag its header down, reopen it, and tap the backdrop to dismiss it.
- [Sheet](android-sheet.png): the report form and exposed backdrop.
- [Draft protection](android-draft-protection.png): a backdrop tap asks before discarding synthetic input; Keep editing retains the draft. The same confirmation was verified after dragging a populated sheet.

The recording uses the platform recorder; the connected gesture backend was unavailable on this older emulator, so native input and accessibility inspection verified the actual app. Four Robolectric gesture tests also cover finger tracking, short/cancelled drags, content scrolling/saving, and interruption while the sheet returns to rest.

## iOS

Seven targeted native UI checks passed on iPhone 17 Pro Max, iOS 26.4, covering empty backdrop dismissal/reopening, populated draft protection, short-drag return, slow-drag dismissal/reopening, the existing grabber dismissal, keyboard geometry/refocus, and rotation/background restoration.

- [Sheet and exposed backdrop](ios-sheet-backdrop.png).
- [Backdrop protects a populated draft](ios-backdrop-protects-draft.png).
- [Host restored after a slow drag](ios-sheet-drag-dismissed.png).

These screenshots are unmodified XCTest attachments. The successful slow-drag check also reopens the reporter after this final host capture. No temporary application lifecycle or UI-test capture harness was included in this change.

## Commands

- `npm ci`
- `npm run contracts:check`
- `npm run test:ios` — 49 tests.
- `npm run test:android` — 72 tests, including four gesture regressions.
- `JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home ANDROID_HOME=/Users/alex/Library/Android/sdk ./packages/android/gradlew -p packages/android :demo:assembleDebug`
- `xcodebuild test -project examples/ios/CrumbDemo.xcodeproj -scheme CrumbDemo -destination 'platform=iOS Simulator,id=309A0387-F103-4698-A2C9-55F45C196711' -derivedDataPath /private/tmp/crumb-task7-after-build -parallel-testing-enabled NO -only-testing:CrumbDemoUITests/CrumbDemoUITests/testInteractiveDismissalAllowsAnotherReport -only-testing:CrumbDemoUITests/CrumbDemoUITests/testBackdropDismissalAllowsAnotherReport -only-testing:CrumbDemoUITests/CrumbDemoUITests/testBackdropDismissalKeepsDraftUntilDiscardIsConfirmed -only-testing:CrumbDemoUITests/CrumbDemoUITests/testSlowSheetDragDismissesAndAllowsAnotherReport -only-testing:CrumbDemoUITests/CrumbDemoUITests/testShortSheetDragReturnsToItsRestingPosition -only-testing:CrumbDemoUITests/CrumbDemoUITests/testDescriptionKeepsItsGeometryThroughTypingAndRefocus -only-testing:CrumbDemoUITests/CrumbDemoUITests/testReportSurvivesRotationAndBackgrounding CODE_SIGNING_ALLOWED=NO` — seven passed.
