import { useState } from 'react';
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

  const startCrumb = async () => {
    try {
      await Crumb.start({
        projectKey: 'replace-with-your-project-key',
        environment: 'development',
        release: { bundleVersion: 'expo-development-build' },
        diagnostics: { logs: { captureConsole: true } },
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

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar style="auto" />
      <View style={styles.container}>
        <Text style={styles.eyebrow}>CRUMB REACT NATIVE</Text>
        <Text style={styles.title}>Native reporting, one adapter.</Text>
        <Text style={styles.body}>
          This Expo development build exercises the same Swift and Kotlin SDKs
          used by native apps.
        </Text>

        <View style={styles.actions}>
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
        </View>
      </View>
    </SafeAreaView>
  );
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
