import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { RootTabParamList } from './RootStackParams';
import { AuthScreen } from '../features/auth/screens/AuthScreen';
import { CatalogScreen } from '../features/catalog/screens/CatalogScreen';
import { OrdersScreen } from '../features/orders/screens/OrdersScreen';
import { GamificationScreen } from '../features/gamification/screens/GamificationScreen';
import { AggregatorScreen } from '../features/aggregator/screens/AggregatorScreen';

const Tab = createBottomTabNavigator<RootTabParamList>();

export function AppNavigator() {
  return (
    <NavigationContainer>
      <Tab.Navigator>
        <Tab.Screen name="Auth" component={AuthScreen} />
        <Tab.Screen name="Catalog" component={CatalogScreen} />
        <Tab.Screen name="Orders" component={OrdersScreen} />
        <Tab.Screen name="Gamification" component={GamificationScreen} />
        <Tab.Screen name="Aggregator" component={AggregatorScreen} />
      </Tab.Navigator>
    </NavigationContainer>
  );
}
