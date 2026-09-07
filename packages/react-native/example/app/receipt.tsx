import { Button } from 'react-native';
import { router } from 'expo-router';
import { DemoControls } from '../src/navigation/DemoControls';
export default function Receipt() {
  return (
    <DemoControls title="Receipt">
      <Button title="Dismiss Receipt" onPress={() => router.back()} />
    </DemoControls>
  );
}
