import {
  createContext,
  useContext,
  useState,
  type PropsWithChildren,
} from 'react';
import {
  Alert,
  Button,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import Crumb from '@crumbsdk/react-native';

const Started = createContext(false);

export function DemoSession({ children }: PropsWithChildren) {
  const [started, setStarted] = useState(false);
  async function start() {
    try {
      await Crumb.start({
        projectKey:
          process.env.EXPO_PUBLIC_CRUMB_PROJECT_KEY ||
          'synthetic-navigation-demo',
        environment: 'navigation-demo',
        release: {
          bundleVersion:
            process.env.EXPO_PUBLIC_CRUMB_BUNDLE_VERSION ||
            'navigation-demo-local',
        },
        diagnostics: {
          javascriptCrashCapture: { enabled: true },
          renderingEnabled: true,
        },
      });
      await Crumb.installReporter();
      setStarted(true);
    } catch (error) {
      Alert.alert('Could not start Crumb', String(error));
    }
  }
  return (
    <Started.Provider value={started}>
      <View style={styles.root}>
        <View style={styles.start}>
          <Button
            title={started ? 'Crumb started' : 'Start Crumb'}
            onPress={start}
          />
        </View>
        {children}
      </View>
    </Started.Provider>
  );
}

export function DemoControls({
  title,
  children,
}: PropsWithChildren<{ title: string }>) {
  const started = useContext(Started);
  return (
    <ScrollView contentContainerStyle={styles.content}>
      <Text style={styles.title}>{title}</Text>
      <Text>Automatic screen tracking. Reports stay on this device.</Text>
      {children}
      <Button
        title="Open reporter"
        disabled={!started}
        onPress={() => {
          Crumb.show().catch((error: unknown) =>
            Alert.alert('Reporter unavailable', String(error))
          );
        }}
      />
      <Button
        title="Trigger JS fatal fixture"
        disabled={!started}
        onPress={() =>
          Alert.alert(
            'Fatal fixture',
            'Relaunch and choose Start Crumb to recover the original screen.',
            [
              { text: 'Cancel', style: 'cancel' },
              {
                text: 'Crash now',
                style: 'destructive',
                onPress: () => setTimeout(crashNavigationFixture, 250),
              },
            ]
          )
        }
      />
    </ScrollView>
  );
}

function crashNavigationFixture() {
  throw new Error('Synthetic navigation crash');
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#f7f7f4' },
  start: { paddingTop: 60, paddingHorizontal: 24 },
  content: { padding: 24, gap: 18 },
  title: { fontSize: 28, fontWeight: '600', color: '#17191c' },
});
