import { useEffect, useState } from 'react';
import {
  Alert,
  Platform,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { StatusBar } from 'expo-status-bar';
import Crumb from '@crumbsdk/react-native';

export default function App() {
  const [isStarted, setIsStarted] = useState(false);
  const [screen, setScreen] = useState<'Home' | 'Checkout'>('Home');
  useEffect(() => {
    Crumb.setScreen(screen, { route: ['Demo', screen] });
    return () => Crumb.setScreen(null);
  }, [screen]);

  const startCrumb = async () => {
    const projectKey = process.env.EXPO_PUBLIC_CRUMB_PROJECT_KEY;
    if (!projectKey) {
      Alert.alert(
        'Demo configuration missing',
        'Set EXPO_PUBLIC_CRUMB_PROJECT_KEY before building this demo.'
      );
      return;
    }
    try {
      await Crumb.start({
        projectKey,
        environment: process.env.EXPO_PUBLIC_CRUMB_ENVIRONMENT || 'development',
        release: {
          bundleVersion:
            process.env.EXPO_PUBLIC_CRUMB_BUNDLE_VERSION ||
            'expo-development-build',
        },
        ...(process.env.EXPO_PUBLIC_CRUMB_INGESTION_URL
          ? {
              upload: {
                ingestionUrl: process.env.EXPO_PUBLIC_CRUMB_INGESTION_URL,
              },
            }
          : {}),
        diagnostics: {
          renderingEnabled: true,
          logs: { captureConsole: true },
          // Opt-in: the next launch recovers this JavaScript failure.
          javascriptCrashCapture: { enabled: true },
        },
      });
      const installed = await Crumb.installReporter();
      setIsStarted(installed);
      Alert.alert('Crumb is ready', 'Shake the device or open the reporter.');
    } catch (error) {
      Alert.alert('Could not start Crumb', String(error));
    }
  };

  const openReporter = async () => {
    const opened = await Crumb.show();
    if (!opened) {
      Alert.alert('Reporter unavailable', 'Start Crumb first and try again.');
    }
  };

  const addTestLog = () => {
    Crumb.log('notice', 'React Native example action', {
      platform: Platform.OS,
      occurredAt: new Date().toISOString(),
    });
    Alert.alert('Log captured', 'Open the reporter to include it.');
  };

  const triggerJavaScriptFatalFixture = () => {
    Alert.alert(
      'Fatal fixture',
      'The app will terminate. Relaunch it and choose Start Crumb to recover this failure.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Crash now',
          style: 'destructive',
          onPress: () => setTimeout(crashDemoAtKnownSourceLine, 250),
        },
      ]
    );
  };

  const triggerUnhandledRejectionFixture = () => {
    Promise.reject(new Error('Crumb React Native unhandled rejection fixture'));
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar style="auto" />
      <View style={styles.container}>
        <Text style={styles.eyebrow}>CRUMB REACT NATIVE</Text>
        <Text style={styles.title}>{screen}</Text>
        <Text style={styles.body}>
          This demo build exercises the same Swift and Kotlin SDKs used by
          native apps.
        </Text>

        <View style={styles.actions}>
          <Action
            label={screen === 'Home' ? 'Open Checkout' : 'Go Home'}
            onPress={() => setScreen(screen === 'Home' ? 'Checkout' : 'Home')}
          />
          <Action
            label={isStarted ? 'Crumb started' : 'Start Crumb'}
            onPress={startCrumb}
          />
          <Action
            label="Open reporter"
            onPress={openReporter}
            disabled={!isStarted}
          />
          <Action
            label="Add test log"
            onPress={addTestLog}
            disabled={!isStarted}
          />
          <Action
            label="Trigger JS fatal fixture"
            onPress={triggerJavaScriptFatalFixture}
            disabled={!isStarted}
          />
          <Action
            label="Trigger unhandled rejection fixture"
            onPress={triggerUnhandledRejectionFixture}
            disabled={!isStarted}
          />
        </View>
      </View>
    </SafeAreaView>
  );
}

function crashDemoAtKnownSourceLine() {
  throw new Error('Crumb React Native fatal fixture');
}

interface ActionProps {
  label: string;
  onPress: () => void;
  disabled?: boolean;
}

function Action({ label, onPress, disabled = false }: ActionProps) {
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        disabled && styles.buttonDisabled,
        pressed && !disabled && styles.buttonPressed,
      ]}
    >
      <Text style={styles.buttonLabel}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#f7f7f4',
  },
  container: {
    flex: 1,
    justifyContent: 'center',
    paddingHorizontal: 28,
  },
  eyebrow: {
    color: '#047857',
    fontSize: 13,
    fontWeight: '700',
    letterSpacing: 2.2,
    marginBottom: 16,
  },
  title: {
    color: '#17191c',
    fontSize: 44,
    fontWeight: '700',
    letterSpacing: -1.6,
    lineHeight: 48,
  },
  body: {
    color: '#687080',
    fontSize: 18,
    lineHeight: 28,
    marginTop: 18,
  },
  actions: {
    gap: 12,
    marginTop: 42,
  },
  button: {
    alignItems: 'center',
    backgroundColor: '#13c58f',
    borderRadius: 16,
    minHeight: 54,
    justifyContent: 'center',
    paddingHorizontal: 20,
  },
  buttonDisabled: {
    backgroundColor: '#cbd1d8',
  },
  buttonPressed: {
    opacity: 0.82,
    transform: [{ scale: 0.99 }],
  },
  buttonLabel: {
    color: '#10221c',
    fontSize: 17,
    fontWeight: '600',
  },
});
