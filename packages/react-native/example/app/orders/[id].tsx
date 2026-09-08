import { Button } from 'react-native';
import { router } from 'expo-router';
import { DemoControls } from '../../src/navigation/DemoControls';
export default function Order() {
  return (
    <DemoControls title="Order details">
      <Button title="Open Receipt" onPress={() => router.push('/receipt')} />
      <Button title="Go Home" onPress={() => router.dismissTo('/')} />
    </DemoControls>
  );
}
