import { Button } from 'react-native';
import { router } from 'expo-router';
import { DemoControls } from '../src/navigation/DemoControls';
export default function Home() {
  return (
    <DemoControls title="Home">
      <Button
        title="Open Order"
        onPress={() =>
          router.push({
            pathname: '/orders/[id]',
            params: { id: 'synthetic-order-42', query: 'synthetic-query' },
          })
        }
      />
    </DemoControls>
  );
}
