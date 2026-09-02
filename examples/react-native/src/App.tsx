import { useState } from 'react';
import {
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import Crumb from '@crumbsdk/react-native';
import { StatusBar } from 'expo-status-bar';

import { createCrumbConfiguration, crumbSetup } from './crumb';

type RuntimeStatus = 'idle' | 'starting' | 'ready' | 'error';

export default function App() {
  const [runtimeStatus, setRuntimeStatus] = useState<RuntimeStatus>('idle');
  const [message, setMessage] = useState(
    crumbSetup.isConfigured
      ? 'Configuration found. Start Crumb to install the reporter.'
      : 'Add your project key to .env.local before starting Crumb.'
  );

  const startCrumb = async () => {
    setRuntimeStatus('starting');
    setMessage('Starting the native SDK…');

    try {
      await Crumb.start(createCrumbConfiguration());
      const installed = await Crumb.installReporter();

      if (!installed) {
        throw new Error('The native reporter could not be installed.');
      }

      Crumb.log('info', 'React Native example started', {
        platform: Platform.OS,
      });
      setRuntimeStatus('ready');
      setMessage('Crumb is ready. Shake the device or open the reporter.');
    } catch (error) {
      setRuntimeStatus('error');
      setMessage(error instanceof Error ? error.message : String(error));
    }
  };

  const openReporter = async () => {
    try {
      const opened = await Crumb.show();
      setMessage(
        opened
          ? 'Reporter opened through the Nitro Module.'
          : 'The reporter did not open. Start Crumb and try again.'
      );
    } catch (error) {
      setRuntimeStatus('error');
      setMessage(error instanceof Error ? error.message : String(error));
    }
  };

  const captureTestLog = () => {
    Crumb.log('notice', 'Example app test action', {
      platform: Platform.OS,
      occurredAt: new Date().toISOString(),
    });
    setMessage('Test log captured. It will be attached to the next report.');
  };

  const triggerFatalJavaScriptError = () => {
    throw new Error('Synthetic fatal JavaScript error from the example.');
  };

  const triggerUnhandledRejection = () => {
    void Promise.reject(
      new Error('Synthetic unhandled promise rejection from the example.')
    );
    setMessage('Synthetic unhandled rejection raised.');
  };

  const isReady = runtimeStatus === 'ready';
  const isStarting = runtimeStatus === 'starting';

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar style="dark" />
      <ScrollView
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.header}>
          <View style={styles.mark} accessibilityElementsHidden>
            <Text style={styles.markText}>C</Text>
          </View>
          <Text style={styles.eyebrow}>CRUMB SDK · EXPO</Text>
          <Text style={styles.title}>A real package, inside a real app.</Text>
          <Text style={styles.body}>
            This development build installs the public npm package and reaches
            the native Crumb SDKs through Nitro Modules.
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardLabel}>INTEGRATION STATUS</Text>
          <StatusRow label="Published npm package" value="0.0.1-rc.3" />
          <StatusRow label="Native architecture" value="Nitro Modules" />
          <StatusRow
            label="Project key"
            value={crumbSetup.isConfigured ? 'Configured' : 'Missing'}
            isWarning={!crumbSetup.isConfigured}
          />
          <StatusRow
            label="Report uploads"
            value={crumbSetup.hasIngestionUrl ? 'Enabled' : 'Local only'}
          />
          <StatusRow label="Environment" value={crumbSetup.environment} />
        </View>

        <View
          accessibilityLiveRegion="polite"
          style={[
            styles.notice,
            runtimeStatus === 'error' && styles.noticeError,
            isReady && styles.noticeReady,
          ]}
        >
          <View
            style={[
              styles.noticeDot,
              runtimeStatus === 'error' && styles.noticeDotError,
              isReady && styles.noticeDotReady,
            ]}
          />
          <Text style={styles.noticeText}>{message}</Text>
        </View>

        <View style={styles.actions}>
          <Action
            label={isStarting ? 'Starting…' : isReady ? 'Crumb started' : 'Start Crumb'}
            onPress={startCrumb}
            disabled={!crumbSetup.isConfigured || isStarting || isReady}
          />
          <Action
            label="Open reporter"
            onPress={openReporter}
            disabled={!isReady}
            variant="secondary"
          />
          <Action
            label="Capture test log"
            onPress={captureTestLog}
            disabled={!isReady}
            variant="quiet"
          />
          <Action
            label="Trigger fatal JS error"
            onPress={triggerFatalJavaScriptError}
            disabled={!isReady}
            variant="quiet"
          />
          <Action
            label="Trigger unhandled rejection"
            onPress={triggerUnhandledRejection}
            disabled={!isReady}
            variant="quiet"
          />
        </View>

        {!crumbSetup.isConfigured && (
          <View style={styles.setup}>
            <Text style={styles.setupLabel}>ONE-TIME SETUP</Text>
            <Text style={styles.setupCode}>
              cp .env.example .env.local
            </Text>
            <Text style={styles.setupText}>
              Replace the placeholder with a dashboard project key, then
              restart the development server.
            </Text>
          </View>
        )}
      </ScrollView>
    </SafeAreaView>
  );
}

interface StatusRowProps {
  label: string;
  value: string;
  isWarning?: boolean;
}

function StatusRow({ label, value, isWarning = false }: StatusRowProps) {
  return (
    <View style={styles.statusRow}>
      <Text style={styles.statusLabel}>{label}</Text>
      <Text style={[styles.statusValue, isWarning && styles.statusWarning]}>
        {value}
      </Text>
    </View>
  );
}

interface ActionProps {
  label: string;
  onPress: () => void | Promise<void>;
  disabled?: boolean;
  variant?: 'primary' | 'secondary' | 'quiet';
}

function Action({
  label,
  onPress,
  disabled = false,
  variant = 'primary',
}: ActionProps) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        variant === 'secondary' && styles.buttonSecondary,
        variant === 'quiet' && styles.buttonQuiet,
        disabled && styles.buttonDisabled,
        pressed && !disabled && styles.buttonPressed,
      ]}
    >
      <Text
        style={[
          styles.buttonLabel,
          variant !== 'primary' && styles.buttonLabelSecondary,
          disabled && styles.buttonLabelDisabled,
        ]}
      >
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#f7f7f4',
  },
  content: {
    flexGrow: 1,
    gap: 24,
    paddingHorizontal: 24,
    paddingBottom: 36,
    paddingTop: 32,
  },
  header: {
    gap: 14,
  },
  mark: {
    alignItems: 'center',
    backgroundColor: '#17191c',
    borderCurve: 'continuous',
    borderRadius: 14,
    height: 44,
    justifyContent: 'center',
    marginBottom: 8,
    width: 44,
  },
  markText: {
    color: '#13c58f',
    fontSize: 22,
    fontWeight: '800',
  },
  eyebrow: {
    color: '#047857',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 2.2,
  },
  title: {
    color: '#17191c',
    fontSize: 42,
    fontWeight: '700',
    letterSpacing: -1.5,
    lineHeight: 46,
  },
  body: {
    color: '#687080',
    fontSize: 17,
    lineHeight: 26,
  },
  card: {
    backgroundColor: '#ffffff',
    borderColor: '#dedfe3',
    borderCurve: 'continuous',
    borderRadius: 20,
    borderWidth: 1,
    padding: 20,
  },
  cardLabel: {
    color: '#687080',
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 1.8,
    marginBottom: 8,
  },
  statusRow: {
    alignItems: 'center',
    borderBottomColor: '#ececef',
    borderBottomWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    gap: 16,
    justifyContent: 'space-between',
    minHeight: 42,
  },
  statusLabel: {
    color: '#525966',
    flex: 1,
    fontSize: 14,
  },
  statusValue: {
    color: '#17191c',
    fontSize: 14,
    fontWeight: '600',
    textAlign: 'right',
  },
  statusWarning: {
    color: '#b45309',
  },
  notice: {
    alignItems: 'flex-start',
    backgroundColor: '#eef0f2',
    borderCurve: 'continuous',
    borderRadius: 16,
    flexDirection: 'row',
    gap: 12,
    padding: 16,
  },
  noticeReady: {
    backgroundColor: '#ddf8ec',
  },
  noticeError: {
    backgroundColor: '#fee9e5',
  },
  noticeDot: {
    backgroundColor: '#89909b',
    borderRadius: 5,
    height: 10,
    marginTop: 5,
    width: 10,
  },
  noticeDotReady: {
    backgroundColor: '#0f9f75',
  },
  noticeDotError: {
    backgroundColor: '#e45e47',
  },
  noticeText: {
    color: '#424954',
    flex: 1,
    fontSize: 14,
    lineHeight: 20,
  },
  actions: {
    gap: 10,
  },
  button: {
    alignItems: 'center',
    backgroundColor: '#13c58f',
    borderColor: '#13c58f',
    borderCurve: 'continuous',
    borderRadius: 16,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 54,
    paddingHorizontal: 20,
  },
  buttonSecondary: {
    backgroundColor: '#17191c',
    borderColor: '#17191c',
  },
  buttonQuiet: {
    backgroundColor: 'transparent',
    borderColor: '#cfd2d7',
  },
  buttonDisabled: {
    backgroundColor: '#e8e9eb',
    borderColor: '#e8e9eb',
  },
  buttonPressed: {
    opacity: 0.84,
    transform: [{ scale: 0.99 }],
  },
  buttonLabel: {
    color: '#10221c',
    fontSize: 16,
    fontWeight: '700',
  },
  buttonLabelSecondary: {
    color: '#ffffff',
  },
  buttonLabelDisabled: {
    color: '#9298a2',
  },
  setup: {
    gap: 10,
    paddingTop: 4,
  },
  setupLabel: {
    color: '#687080',
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 1.8,
  },
  setupCode: {
    backgroundColor: '#17191c',
    borderCurve: 'continuous',
    borderRadius: 12,
    color: '#13c58f',
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 13,
    overflow: 'hidden',
    padding: 14,
  },
  setupText: {
    color: '#687080',
    fontSize: 14,
    lineHeight: 21,
  },
});
