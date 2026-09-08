// Build-time selection keeps the two automatic trackers independent.
if (process.env.EXPO_PUBLIC_CRUMB_NAVIGATION === 'expo-router') {
  require('expo-router/entry');
} else {
  const { registerRootComponent } = require('expo');
  const App =
    process.env.EXPO_PUBLIC_CRUMB_NAVIGATION === 'react-navigation'
      ? require('./src/navigation/ReactNavigationDemo').default
      : require('./src/App').default;
  registerRootComponent(App);
}
