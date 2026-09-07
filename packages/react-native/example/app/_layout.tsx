import { Stack, useSegments } from 'expo-router';
import { useExpoRouterScreen } from '@crumbsdk/react-native';
import { DemoSession } from '../src/navigation/DemoControls';

export default function RootLayout() {
  useExpoRouterScreen(useSegments());
  return (
    <DemoSession>
      <Stack>
        <Stack.Screen name="receipt" options={{ presentation: 'modal' }} />
      </Stack>
    </DemoSession>
  );
}
