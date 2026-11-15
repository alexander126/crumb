// Example-only workarounds that let an Expo SDK 55 project build with Xcode 27
// and launch on iOS 27. Expo adopts both upstream from SDK 58, so remove this
// plugin when the example moves to an Expo SDK that ships them.
//
// The file is CommonJS and resolves @expo/config-plugins lazily, so the pure
// transforms below can be tested without an Expo installation on the path.

const MARKER = 'crumb-example-ios-27';

// Xcode 27 refuses to build a target below this iOS version. React Native's
// post-install step raises each pod's main target, but leaves resource-bundle
// targets at the value from the podspec (9.0 for SDWebImage).
const MINIMUM_POD_DEPLOYMENT_TARGET = '15.0';

const POST_INSTALL = /^([ \t]*)post_install do \|installer\|[ \t]*$/m;

function raisePodDeploymentTargets(podfile) {
  if (podfile.includes(MARKER)) return podfile;
  if (!POST_INSTALL.test(podfile)) {
    throw new Error(
      'with-ios-27-compat could not find the post_install block in the generated Podfile. The Expo template changed; update the plugin.'
    );
  }
  return podfile.replace(POST_INSTALL, (line, indent) => {
    const body = [
      `# ${MARKER}: Xcode 27 rejects targets below iOS ${MINIMUM_POD_DEPLOYMENT_TARGET}, and some pods`,
      '# still declare an older version for their resource bundles.',
      `minimum_pod_target = Gem::Version.new('${MINIMUM_POD_DEPLOYMENT_TARGET}')`,
      'installer.pods_project.targets.each do |pod_target|',
      '  pod_target.build_configurations.each do |build_configuration|',
      "    declared = build_configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET']",
      '    next if declared.nil? || Gem::Version.new(declared) >= minimum_pod_target',
      "    build_configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = minimum_pod_target.to_s",
      '  end',
      'end',
      '',
    ]
      .map((text) => (text ? `${indent}  ${text}` : text))
      .join('\n');
    return `${line}\n${body}`;
  });
}

// The SDK 55 template creates the window and starts React Native from the app
// delegate. iOS 27 terminates an app built with its SDK unless a scene delegate
// does that instead.
const APP_DELEGATE_START =
  /#if os\(iOS\) \|\| os\(tvOS\)\n\s*window = UIWindow\(frame: UIScreen\.main\.bounds\)\n\s*factory\.startReactNative\(\n\s*withModuleName: "([^"]+)",\n\s*in: window,\n\s*launchOptions: launchOptions\)\n#endif\n/;

function sceneDelegateSource(moduleName) {
  return `
// ${MARKER}: iOS 27 requires the UIScene life cycle. The scene delegate owns the
// window and starts React Native; everything else is handed to the app delegate,
// which keeps forwarding to Expo's subscribers and to React Native's linking.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
      let appDelegate = UIApplication.shared.delegate as? AppDelegate,
      let factory = appDelegate.reactNativeFactory
    else {
      fatalError("SceneDelegate needs the AppDelegate to create the React Native factory at launch.")
    }

    let window = UIWindow(windowScene: windowScene)
    self.window = window
    // Libraries still read the window from the app delegate.
    appDelegate.window = window

    factory.startReactNative(
      withModuleName: "${moduleName}",
      in: window,
      launchOptions: Self.launchOptions(from: connectionOptions))

    // UIKit reports a link that starts the app only in the connection options. Replay it so the
    // app delegate's subscribers (expo-linking, which Expo Router reads) see it as they used to.
    open(connectionOptions.urlContexts)
    connectionOptions.userActivities.forEach(continueUserActivity)
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    window = nil
  }

  // UIKit stops calling the app delegate's life-cycle methods once scenes are adopted.
  func sceneDidBecomeActive(_ scene: UIScene) {
    appDelegate?.applicationDidBecomeActive(UIApplication.shared)
  }

  func sceneWillResignActive(_ scene: UIScene) {
    appDelegate?.applicationWillResignActive(UIApplication.shared)
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    appDelegate?.applicationWillEnterForeground(UIApplication.shared)
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    appDelegate?.applicationDidEnterBackground(UIApplication.shared)
  }

  // Deep links while the app is running.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    open(URLContexts)
  }

  // Universal links while the app is running.
  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    continueUserActivity(userActivity)
  }

  private func open(_ contexts: Set<UIOpenURLContext>) {
    for context in contexts {
      var options: [UIApplication.OpenURLOptionsKey: Any] = [.openInPlace: context.options.openInPlace]
      if let sourceApplication = context.options.sourceApplication {
        options[.sourceApplication] = sourceApplication
      }
      if let annotation = context.options.annotation {
        options[.annotation] = annotation
      }
      _ = appDelegate?.application(UIApplication.shared, open: context.url, options: options)
    }
  }

  private func continueUserActivity(_ userActivity: NSUserActivity) {
    _ = appDelegate?.application(UIApplication.shared, continue: userActivity) { _ in }
  }

  private var appDelegate: AppDelegate? {
    UIApplication.shared.delegate as? AppDelegate
  }

  // A link that starts the app arrives in the scene's connection options. React Native's
  // Linking.getInitialURL() reads launch options, so rebuild the entries it looks for. The keys
  // are spelled out because their UIApplication accessors are deprecated in favor of scenes.
  private static func launchOptions(
    from connectionOptions: UIScene.ConnectionOptions
  ) -> [UIApplication.LaunchOptionsKey: Any]? {
    var launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]
    if let url = connectionOptions.urlContexts.first?.url {
      launchOptions[UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsURLKey")] = url
    }
    let webActivity = connectionOptions.userActivities.first {
      $0.activityType == NSUserActivityTypeBrowsingWeb
    }
    if let webActivity {
      launchOptions[
        UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsUserActivityDictionaryKey")
      ] = [
        "UIApplicationLaunchOptionsUserActivityTypeKey": webActivity.activityType,
        "UIApplicationLaunchOptionsUserActivityKey": webActivity,
      ]
    }
    return launchOptions.isEmpty ? nil : launchOptions
  }
}
`;
}

function adoptSceneLifeCycle(appDelegate) {
  if (appDelegate.includes(MARKER)) return appDelegate;
  const start = APP_DELEGATE_START.exec(appDelegate);
  if (!start) {
    throw new Error(
      'with-ios-27-compat could not find where the generated AppDelegate.swift starts React Native. The Expo template changed; update the plugin.'
    );
  }
  return (
    appDelegate.replace(
      APP_DELEGATE_START,
      `    // ${MARKER}: SceneDelegate creates the window and starts React Native.\n`
    ) + sceneDelegateSource(start[1])
  );
}

const SCENE_MANIFEST = {
  UIApplicationSupportsMultipleScenes: false,
  UISceneConfigurations: {
    UIWindowSceneSessionRoleApplication: [
      {
        UISceneConfigurationName: 'Default Configuration',
        UISceneDelegateClassName: '$(PRODUCT_MODULE_NAME).SceneDelegate',
      },
    ],
  },
};

function withIos27Compat(config) {
  const {
    withAppDelegate,
    withInfoPlist,
    withPodfile,
  } = require('@expo/config-plugins');

  config = withPodfile(config, (modConfig) => {
    modConfig.modResults.contents = raisePodDeploymentTargets(
      modConfig.modResults.contents
    );
    return modConfig;
  });
  config = withAppDelegate(config, (modConfig) => {
    if (modConfig.modResults.language !== 'swift') {
      throw new Error(
        'with-ios-27-compat expects the Swift AppDelegate from the Expo template.'
      );
    }
    modConfig.modResults.contents = adoptSceneLifeCycle(
      modConfig.modResults.contents
    );
    return modConfig;
  });
  return withInfoPlist(config, (modConfig) => {
    modConfig.modResults.UIApplicationSceneManifest = SCENE_MANIFEST;
    return modConfig;
  });
}

module.exports = withIos27Compat;
module.exports.adoptSceneLifeCycle = adoptSceneLifeCycle;
module.exports.raisePodDeploymentTargets = raisePodDeploymentTargets;
