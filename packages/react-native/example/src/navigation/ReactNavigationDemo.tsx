import { useEffect } from 'react';
import { Button } from 'react-native';
import {
  createNavigationContainerRef,
  createStaticNavigation,
  useNavigation,
  type StaticParamList,
  type StaticScreenProps,
  StackActions,
} from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import Crumb from '@crumbsdk/react-native';
import { DemoControls, DemoSession } from './DemoControls';

function Home() {
  return (
    <DemoControls title="Home">
      <Button
        title="Open Shop"
        onPress={() =>
          navigation.navigate('Shop', {
            screen: 'Checkout',
            params: {
              customerId: 'synthetic-customer-42',
              query: 'synthetic-query',
            },
          })
        }
      />
    </DemoControls>
  );
}
function Checkout(
  _props: StaticScreenProps<{ customerId: string; query: string }>
) {
  return (
    <DemoControls title="Checkout">
      <Button
        title="Open Receipt"
        onPress={() => navigation.navigate('Receipt')}
      />
      <Button
        title="Go Home"
        onPress={() => navigation.dispatch(StackActions.popToTop())}
      />
    </DemoControls>
  );
}
function Receipt() {
  const current = useNavigation();
  return (
    <DemoControls title="Receipt">
      <Button title="Dismiss Receipt" onPress={() => current.goBack()} />
    </DemoControls>
  );
}
// Params deliberately contain synthetic values; Crumb only reads route names.
const Shop = createNativeStackNavigator({
  screens: {
    Checkout: {
      screen: Checkout,
      initialParams: { customerId: '', query: '' },
    },
  },
});
const Root = createNativeStackNavigator({
  screens: {
    Home,
    Shop: { screen: Shop, options: { headerShown: false } },
    Receipt: { screen: Receipt, options: { presentation: 'modal' } },
  },
});
type RootParams = StaticParamList<typeof Root>;
const navigation = createNavigationContainerRef<RootParams>();
const Navigation = createStaticNavigation(Root);

export default function ReactNavigationDemo() {
  useEffect(() => Crumb.trackReactNavigation(navigation), []);
  return (
    <DemoSession>
      <Navigation ref={navigation} />
    </DemoSession>
  );
}
