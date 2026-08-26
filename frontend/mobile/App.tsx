import './global.css';
import { AppNavigator } from './src/navigation/AppNavigator';
import { useAuthBootstrap } from './src/lib/useAuthBootstrap';

export default function App() {
  useAuthBootstrap();
  return <AppNavigator />;
}
